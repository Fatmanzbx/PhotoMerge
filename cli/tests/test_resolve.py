"""Stage 4 — what each merged asset's date and place actually become."""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from photomerge.catalog import open_catalog
from photomerge.resolve import BATCH_MINUTE_CLUSTERS, resolve


def build(tmp_path: Path, assets: dict[str, list[tuple]]):
    """`{asset: [(field, value, source, confidence), ...]}` straight into a catalog."""
    db = open_catalog(tmp_path / "catalog.sqlite")
    for name, claims in assets.items():
        cur = db.execute(
            "INSERT INTO file (path, rel_path, source, source_priority, size, mtime, "
            "status) VALUES (?,?,?,0,1,0,'extracted')", (name, name, "mac"))
        file_id = cur.lastrowid
        cluster_id = db.execute(
            "INSERT INTO cluster (method) VALUES ('exact')").lastrowid
        db.execute("INSERT INTO member (cluster_id, file_id, role) VALUES (?,?,'canonical')",
                   (cluster_id, file_id))
        for f, v, s, c in claims:
            db.execute("INSERT INTO meta (file_id, field, value, source, confidence) "
                       "VALUES (?,?,?,?,?)", (file_id, f, v, s, c))
    return db


def resolved(db, name: str) -> dict[str, tuple[str, str, dict]]:
    out = {}
    for r in db.execute("""SELECT r.field, r.value, r.source, r.competing_json
        FROM resolution r JOIN member m ON m.cluster_id = r.cluster_id
        JOIN file f ON f.id = m.file_id WHERE f.path = ?""", (name,)):
        out[r["field"]] = (r["value"], r["source"],
                           json.loads(r["competing_json"]) if r["competing_json"] else {})
    return out


def test_mtime_is_not_a_capture_time_unless_nothing_else_is(tmp_path):
    """Copying a file resets mtime, so it disagrees with every real capture time
    by years. Left in the pool it marks the entire library as conflicted (D11)."""
    db = build(tmp_path, {
        "has_exif.jpg": [
            ("datetime_utc", "2018-06-01T12:00:00+00:00", "exif", 0.95),
            ("datetime_utc", "2024-11-01T07:02:30+00:00", "fs", 0.05)],
        "only_mtime.jpg": [
            ("datetime_utc", "2024-11-01T07:02:30+00:00", "fs", 0.05)],
    })
    stats = resolve(db)
    assert resolved(db, "has_exif.jpg")["datetime_utc"][0].startswith("2018-06-01")
    assert stats.conflicts == 0, "mtime must not count as a competing claim"
    # ... but it is still better than having no date at all.
    assert resolved(db, "only_mtime.jpg")["datetime_utc"][0].startswith("2024-11-01")


def test_a_whole_hour_gap_is_a_timezone_not_a_conflict(tmp_path):
    db = build(tmp_path, {"a.jpg": [
        ("datetime_utc", "2023-10-02T01:21:34+00:00", "exif", 0.95),
        ("datetime_utc", "2023-10-02T00:21:55+00:00", "google_json", 0.9)]})
    resolve(db)
    got = resolved(db, "a.jpg")["datetime_utc"]
    assert got[1] == "exif"
    assert "tz_resolved" in got[2]["note"]


def test_the_earliest_claim_wins_because_a_timestamp_only_drifts_later(tmp_path):
    """Re-encoding, restoring and re-uploading all push a timestamp forward;
    nothing pushes it back. So on a real disagreement the earliest claim is the
    best estimate even from a source the precedence table ranks low."""
    db = build(tmp_path, {"wechat.jpg": [
        ("datetime_utc", "2017-11-14T15:25:55+00:00", "filename", 0.5),
        ("datetime_utc", "2018-12-30T15:05:47+00:00", "exif", 0.95),
        ("datetime_utc", "2019-01-01T03:05:06+00:00", "google_json", 0.9)]})
    resolve(db)
    got = resolved(db, "wechat.jpg")["datetime_utc"]
    assert got[0].startswith("2017-11-14")
    assert "date_conflict" in got[2]["note"]
    # The alternatives are kept, so the decision can be inspected and reversed.
    assert {c["source"] for c in got[2]["competing"]} == {"exif", "google_json"}


def test_a_timestamp_shared_by_many_assets_is_a_batch_stamp(tmp_path):
    """1,428 EXIF claims in the real library land within four minutes of each
    other: a phone restore stamping files, not 1,428 photographs."""
    assets = {}
    for i in range(BATCH_MINUTE_CLUSTERS + 5):
        assets[f"batch{i}.jpg"] = [
            ("datetime_utc", "2018-12-30T15:14:00+00:00", "exif", 0.95),
            ("datetime_utc", f"2016-03-0{i % 9 + 1}T09:00:00+00:00", "filename", 0.5)]
    db = build(tmp_path, assets)
    stats = resolve(db)
    assert stats.batch_claims_downgraded >= BATCH_MINUTE_CLUSTERS
    # The filename date survives despite ranking far below EXIF.
    assert resolved(db, "batch0.jpg")["datetime_utc"][0].startswith("2016-03")


def test_gps_moves_as_one_value_and_a_far_fix_is_escalated(tmp_path):
    db = build(tmp_path, {
        "near.jpg": [("gps", "38.8911,-77.0168", "exif", 0.95),
                     ("gps", "38.8912,-77.0169", "google_json", 0.9)],
        "far.jpg":  [("gps", "38.8911,-77.0168", "quicktime", 0.9),
                     ("gps", "35.6762,139.6503", "google_json", 0.9)],
    })
    stats = resolve(db)
    assert resolved(db, "near.jpg")["gps"][0] == "38.8911,-77.0168"
    assert stats.gps_review == 1
    assert "gps_conflict" in resolved(db, "far.jpg")["gps"][2]["note"]


def test_a_camera_fix_beats_a_pin_dropped_by_hand(tmp_path):
    """§4.2: the one far-apart disagreement with a known cause."""
    db = build(tmp_path, {"a.jpg": [
        ("gps", "38.8911,-77.0168", "exif", 0.95),
        ("gps", "35.6762,139.6503", "google_json", 0.9)]})
    stats = resolve(db)
    got = resolved(db, "a.jpg")["gps"]
    assert got[1] == "exif" and "kept the camera's fix" in got[2]["note"]
    assert stats.gps_review == 0


def test_a_zone_is_derived_from_the_location(tmp_path):
    db = build(tmp_path, {"tokyo.jpg": [
        ("datetime_utc", "2023-06-01T03:00:00+00:00", "google_json", 0.9),
        ("gps", "35.6762,139.6503", "google_json", 0.9)]})
    stats = resolve(db)
    got = resolved(db, "tokyo.jpg")
    assert got["utc_offset"][0] == "+09:00"
    assert "Tokyo" in got["utc_offset"][2]["note"]
    assert stats.tz_from_gps == 1


def test_a_zone_is_inherited_from_the_nearest_dated_photo(tmp_path):
    """Rank 4b — 83% of this library's offset-less assets have an anchor within
    six hours, and 54% within a minute, which is the same capture session."""
    db = build(tmp_path, {
        "anchor.jpg": [("datetime_utc", "2023-06-01T12:00:00+00:00", "exif", 0.95),
                       ("utc_offset", "-05:00", "exif", 0.9)],
        "orphan.jpg": [("datetime_utc", "2023-06-01T12:00:30+00:00", "google_json", 0.9)],
    })
    stats = resolve(db)
    got = resolved(db, "orphan.jpg")["utc_offset"]
    assert got[0] == "-05:00" and got[1] == "derived"
    assert "nearest dated photo" in got[2]["note"]
    assert stats.tz_from_neighbour == 1


def test_a_wide_inheritance_says_so(tmp_path):
    db = build(tmp_path, {
        "anchor.jpg": [("datetime_utc", "2023-06-01T12:00:00+00:00", "exif", 0.95),
                       ("utc_offset", "-05:00", "exif", 0.9)],
        "orphan.jpg": [("datetime_utc", "2023-08-01T12:00:00+00:00", "google_json", 0.9)],
    })
    resolve(db)
    assert "suspicion" in resolved(db, "orphan.jpg")["utc_offset"][2]["note"]


def test_resolving_twice_changes_nothing(tmp_path):
    db = build(tmp_path, {"a.jpg": [
        ("datetime_utc", "2018-06-01T12:00:00+00:00", "exif", 0.95),
        ("gps", "38.8911,-77.0168", "exif", 0.95),
        ("make", "Apple", "exif", 1.0)]})
    first = resolve(db)
    snapshot = resolved(db, "a.jpg")
    second = resolve(db)
    assert snapshot == resolved(db, "a.jpg")
    assert (first.clusters, first.resolved_time) == (second.clusters, second.resolved_time)


def test_a_quicktime_utc_date_is_not_an_offset_claim(tmp_path):
    """`QuickTime:CreateDate` is UTC by specification, so exiftool renders it
    `+00:00` whatever zone the camera was in. Recorded as the shooting offset it
    made 181 videos in the real library claim UTC as their own wall clock, which
    named and filed them hours out."""
    db = build(tmp_path, {
        "anchor.jpg": [("datetime_utc", "2022-08-17T21:00:00+00:00", "exif", 0.95),
                       ("utc_offset", "-06:00", "exif", 0.9)],
        # What extract now emits for a movie with only a CreateDate: an instant,
        # and no claim at all about the zone.
        "movie.mov": [("datetime_utc", "2022-08-17T21:51:52+00:00", "quicktime", 0.85)],
    })
    resolve(db)
    got = resolved(db, "movie.mov")["utc_offset"]
    assert got[0] == "-06:00" and got[1] == "derived"


def test_a_wall_clock_is_re_anchored_once_the_zone_is_known(tmp_path):
    """A wall clock with no offset is read as UTC so it can be compared at all.
    If a zone is derived afterwards the instant has to move with it, or the file
    is filed and named by a time that was never real."""
    db = build(tmp_path, {
        "anchor.jpg": [("datetime_utc", "2022-08-17T21:00:00+00:00", "exif", 0.95),
                       ("utc_offset", "-06:00", "exif", 0.9)],
        "movie.mov": [("datetime_local", "2022-08-17T15:51:52", "filename", 0.5)],
    })
    stats = resolve(db)
    got = resolved(db, "movie.mov")
    assert stats.reanchored == 1
    assert got["utc_offset"][0] == "-06:00"
    # 15:51:52 local at -06:00 is 21:51:52 UTC, which is what must be stored.
    assert got["datetime_utc"][0].startswith("2022-08-17T21:51:52")
    assert "re-anchored" in got["datetime_utc"][2]["note"]


def day(hour: int) -> str:
    return f"2022-08-17T{hour:02d}:00:00+00:00"


def located(hour: int, lat: float, lon: float):
    return [("datetime_utc", day(hour), "exif", 0.95),
            ("gps", f"{lat},{lon}", "exif", 0.95)]


def unlocated(hour: int):
    return [("datetime_utc", day(hour), "exif", 0.95)]


def test_a_missing_location_is_inferred_from_a_stationary_day(tmp_path):
    """Several fixes across one day, all inside one city, are evidence that the
    day was spent there — enough to place a photo taken between them."""
    db = build(tmp_path, {
        "a.jpg": located(9, 41.8725, -87.6242),
        "b.jpg": located(12, 41.8790, -87.6300),
        "c.jpg": located(18, 41.8800, -87.6250),
        "missing.jpg": unlocated(14),
    })
    stats = resolve(db)
    got = resolved(db, "missing.jpg")["gps"]
    assert stats.gps_inferred == 1
    assert got[1] == "inferred"
    assert "bracketing" in got[2]["note"]
    lat, lon = (float(x) for x in got[0].split(","))
    assert 41.8 < lat < 41.9 and -87.7 < lon < -87.6


def test_a_day_that_spans_a_flight_is_declined(tmp_path):
    """The whole point of the 'one city' condition: a day with two cities has no
    single answer, so it must produce none rather than pick one."""
    db = build(tmp_path, {
        "chicago.jpg": located(9, 41.8725, -87.6242),
        "tokyo.jpg": located(20, 35.6762, 139.6503),
        "missing.jpg": unlocated(14),
    })
    stats = resolve(db)
    assert stats.gps_inferred == 0 and stats.gps_day_too_wide == 1
    assert "gps" not in resolved(db, "missing.jpg")


def test_a_lone_fix_cannot_reach_across_the_day(tmp_path):
    """'All fixes within 0 km' is vacuously true of one point, so a single
    anchor gets a much shorter reach than a demonstrably stationary day."""
    db = build(tmp_path, {
        "anchor.jpg": located(9, 41.8725, -87.6242),
        "near.jpg": unlocated(11),     # 2 h — inside the lone-anchor budget
        "far.jpg": unlocated(20),      # 11 h — not
    })
    stats = resolve(db)
    assert stats.gps_inferred == 1 and stats.gps_gap_too_wide == 1
    assert "single located photo" in resolved(db, "near.jpg")["gps"][2]["note"]
    assert "gps" not in resolved(db, "far.jpg")


def test_a_day_with_no_located_photo_infers_nothing(tmp_path):
    db = build(tmp_path, {"a.jpg": unlocated(9), "b.jpg": unlocated(12)})
    stats = resolve(db)
    assert stats.gps_inferred == 0 and stats.gps_no_anchor == 2


def test_inference_can_be_switched_off(tmp_path):
    db = build(tmp_path, {
        "a.jpg": located(9, 41.8725, -87.6242),
        "missing.jpg": unlocated(10),
    })
    stats = resolve(db, infer_location=False)
    assert stats.gps_inferred == 0
    assert "gps" not in resolved(db, "missing.jpg")


def test_an_inferred_fix_never_becomes_an_anchor_for_another(tmp_path):
    """Chaining would let one guess travel across a library. Only measured
    fixes anchor an inference."""
    db = build(tmp_path, {
        "anchor.jpg": located(9, 41.8725, -87.6242),
        "guess.jpg": unlocated(11),
        "next.jpg": unlocated(23),
    })
    resolve(db)
    # `guess.jpg` is placed, but it cannot then place `next.jpg` 12 h later.
    assert "gps" in resolved(db, "guess.jpg")
    assert "gps" not in resolved(db, "next.jpg")


def test_a_photo_minutes_from_a_fix_is_placed_whatever_the_day_looked_like(tmp_path):
    """The rule this replaces required the whole day inside 25 km, so a
    national-park day spanning 100 km was rejected wholesale — while individual
    photos sat 40 seconds from a known fix. A time gap bounds distance
    physically; the day's spread does not."""
    db = build(tmp_path, {
        "morning.jpg": located(9, 44.50, -110.78),      # one end of the park
        "evening.jpg": located(18, 43.79, -110.66),     # ~80 km away, same day
        "between.jpg": [("datetime_utc", day(9) .replace("09:00", "09:01"), "exif", 0.95)],
    })
    stats = resolve(db)
    got = resolved(db, "between.jpg")["gps"]
    assert stats.gps_from_travel == 1
    assert got[1] == "inferred"
    assert "within about" in got[2]["note"]
    lat, lon = (float(x) for x in got[0].split(","))
    assert round(lat, 1) == 44.5, "it takes the nearest fix in time, not the day's mean"


def test_the_inference_states_its_own_uncertainty(tmp_path):
    db = build(tmp_path, {
        "anchor.jpg": located(9, 41.87, -87.62),
        "close.jpg": [("datetime_utc", day(9).replace("09:00:00", "09:01:00"), "exif", 0.95)],
    })
    resolve(db)
    note = resolved(db, "close.jpg")["gps"][2]["note"]
    assert "1 min away" in note or "60 s away" in note
    assert "km of it" in note


def test_a_photo_far_in_time_from_any_fix_is_left_alone(tmp_path):
    db = build(tmp_path, {
        "anchor.jpg": located(9, 41.87, -87.62),
        "distant.jpg": [("datetime_utc", "2022-08-25T09:00:00+00:00", "exif", 0.95)],
    })
    stats = resolve(db)
    assert "gps" not in resolved(db, "distant.jpg")
    assert stats.gps_from_travel == 0
