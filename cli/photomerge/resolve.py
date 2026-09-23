"""Stage 4 — deciding what each merged asset's metadata actually is.

Stage 3 says which files are one photograph. This stage reads every claim those
files make and picks one answer per field, keeping the competing values beside
it so a wrong decision can be seen and reversed.

Two rules do most of the work, and both came out of the real library rather than
out of theory:

**A capture time can only be wrong late.** Copying, re-encoding, restoring from a
backup and re-uploading all push a timestamp forward; nothing pushes it back. So
when claims genuinely disagree, the earliest plausible one is the best estimate,
even when it comes from a source the precedence table ranks low.

**A timestamp shared by many unrelated photos is not a capture time.** In this
library 1,428 EXIF claims land within four minutes of each other on 2018-12-30,
and 490 QuickTime claims on the day the Apple export ran. A real capture
histogram is nearly flat; a spike is a batch operation stamping files, and every
claim in that spike is worth less than its source rank suggests.
"""

from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass, field
import bisect
import re
from datetime import datetime, timedelta, timezone

_OFFSET_RE = re.compile(r"^([+-])(\d{2}):?(\d{2})$")

AGREE_SECONDS = 60           # §4.1: claims this close are the same claim
TZ_MAX_HOURS = 14            # a whole-hour gap up to this is a timezone artifact
TZ_SLACK_SECONDS = 90        # how far from a whole hour still counts as one
REVIEW_SECONDS = 24 * 3600   # §4.1: a different day is escalated, not guessed
GPS_AGREE_KM = 0.1           # §4.2
GPS_REVIEW_KM = 5.0
# "The same city" for the purpose of inferring a missing location from the rest
# of its day. Measured on this library: a day whose located photos all fall
# inside 25 km resolves 508 unlocated photos across 133 days, while the days
# this rejects are unmistakable travel — 3,125 km, 10,755 km, 11,108 km.
SAME_CITY_KM = 25.0
# How far in time an inference may reach. A day with several fixes that all fall
# inside one city is *evidence* that the day was stationary, so it can carry a
# photo taken hours later. A day with a single fix is not: "all fixes within
# 0 km" is vacuously true of one point, and 63 such inferences in this library
# reached more than three hours, one of them 26. The two cases get different
# budgets because they rest on different amounts of evidence.
LONE_ANCHOR_HOURS = 3.0
OUTSIDE_SPAN_HOURS = 6.0
# A time gap bounds distance physically: whatever the day looked like, you
# cannot have gone far in two minutes. This is what the "same city" test was
# reaching for and missing — a national-park day spans 100 km because you drive
# between basins, so every such day was rejected while individual photos sat
# 40 seconds from a known fix. 232 of that trip's 399 unlocated photos are
# within two minutes of one.
TRAVEL_KMH = 100.0           # generous sustained road speed
TRAVEL_MAX_MINUTES = 60.0    # beyond this the implied radius stops being useful
BATCH_MINUTE_CLUSTERS = 20   # distinct assets sharing a minute before it is suspect
BATCH_PENALTY = 0.25         # what such a claim's confidence is multiplied by
EARLIEST_PLAUSIBLE = 1990    # below this a date is a null atom, not a capture
LOCAL_PENALTY = 0.9          # a wall clock converted with a borrowed offset

# §4.1's precedence, as a tiebreak *within* an agreeing group — never a way to
# outrank an earlier claim from a lesser source.
TIME_RANK = {"manual": -1, "exif": 0, "quicktime": 0, "xmp": 2, "google_json": 3,
             "filename": 4, "fs": 9}
# §4.2. `geoDataExif` and `geoData` are one source here because they are byte
# for byte identical in all 2,280 sidecars that carry both.
GPS_RANK = {"exif": 0, "quicktime": 1, "google_json": 2, "xmp": 3}

SIMPLE_FIELDS = {
    "make": ("exif", "quicktime"), "model": ("exif", "quicktime"),
    "lens": ("exif",), "description": ("google_json", "xmp"),
    "title": ("xmp",), "keywords": ("xmp",), "rating": ("xmp",),
    "favorite": ("google_json",), "people": ("google_json",),
    "album": ("foldername",), "content_id": ("exif", "quicktime"),
}


@dataclass
class ResolveStats:
    clusters: int = 0
    resolved_time: int = 0
    resolved_gps: int = 0
    tz_from_offset: int = 0
    tz_from_gps: int = 0
    tz_from_neighbour: int = 0
    tz_unknown: int = 0
    reanchored: int = 0
    from_prior: int = 0
    conflicts: int = 0
    tz_artifacts: int = 0
    gps_conflicts: int = 0
    review: int = 0
    gps_review: int = 0
    gps_inferred: int = 0
    gps_day_too_wide: int = 0
    gps_no_anchor: int = 0
    gps_gap_too_wide: int = 0
    gps_from_travel: int = 0
    batch_claims_downgraded: int = 0
    by_note: dict[str, int] = field(default_factory=dict)

    def bump(self, key: str) -> None:
        self.by_note[key] = self.by_note.get(key, 0) + 1


def _restore_original_claims(db, claims, prior_path: str) -> int:
    """Replace a file's embedded claims with what its sources originally said.

    On a second round the inputs are the first round's outputs, so every date we
    wrote comes back looking like a camera's own claim — and a mistake from
    round one arrives as evidence. Measured on this library: a video whose date
    a companion-pairing bug had fabricated turned up in round two as a
    competing claim five years from the truth.

    The prior catalog still holds what each file's *sources* actually claimed,
    keyed by where it was written to. Those are the measurements; what the file
    now carries is our conclusion, and a conclusion should not outrank the
    evidence it was drawn from.

    Crucially it restores the whole prior **cluster's** claims, not just the
    surviving file's. The copies that lost round one are gone from disk, and
    with them the competing evidence that decided it — so resolving round two
    from what survives would quietly re-decide hundreds of assets on strictly
    less information than round one had.
    """
    prior_db = sqlite3.connect(prior_path)
    prior_db.row_factory = sqlite3.Row
    written = {r["target_path"]: r["cluster_id"] for r in prior_db.execute(
        "SELECT d.target_path, m.cluster_id FROM decision d "
        "JOIN member m ON m.file_id = d.file_id "
        "WHERE d.target_path IS NOT NULL")}
    if not written:
        return 0

    here = {r["rel_path"]: (r["id"], r["cluster_id"]) for r in db.execute(
        "SELECT f.rel_path, f.id, m.cluster_id FROM file f "
        "JOIN member m ON m.file_id = f.id")}
    replaced = 0
    for rel_path, (file_id, cluster_id) in here.items():
        prior_cluster = written.get(rel_path)
        if prior_cluster is None:
            continue
        originals = prior_db.execute(
            "SELECT x.field, x.value, x.source, x.confidence FROM meta x "
            "JOIN member m ON m.file_id = x.file_id WHERE m.cluster_id = ? "
            "AND x.field IN ('datetime_utc', 'datetime_local', 'utc_offset')",
            (prior_cluster,)).fetchall()
        if not originals:
            continue
        fields = claims.get(cluster_id)
        if fields is None:
            continue
        for name in ("datetime_utc", "datetime_local", "utc_offset"):
            fields[name] = [c for c in fields.get(name, []) if c.source == "fs"]
        for r in originals:
            bucket = fields.setdefault(r["field"], [])
            if not any(c.value == r["value"] and c.source == r["source"]
                       for c in bucket):
                bucket.append(Claim(r["value"], r["source"], r["confidence"]))

        # A decision a person made by hand outranks every measurement, and must
        # survive into later rounds — otherwise the next run quietly reverts it
        # to whatever the files claim.
        for r in prior_db.execute(
            "SELECT field, value FROM resolution WHERE cluster_id = ? "
            "AND source = 'manual'", (prior_cluster,)
        ):
            fields[r["field"]] = [Claim(r["value"], "manual", 1.0)]
        replaced += 1
    prior_db.close()
    return replaced


@dataclass
class Claim:
    value: str
    source: str
    confidence: float
    instant: float | None = None      # epoch seconds, when the value is a time
    # True when the value is a wall clock that had no offset to convert it with,
    # so it was read as UTC and must be re-anchored once a zone is known.
    unanchored: bool = False


def resolve(
    db: sqlite3.Connection,
    *,
    infer_location: bool = True,
    location_radius_km: float = SAME_CITY_KM,
    prior: str | None = None,
    progress=None,
) -> ResolveStats:
    stats = ResolveStats()
    suspect = _batch_timestamps(db)
    stats.batch_claims_downgraded = sum(suspect.values())
    claims = _claims_by_cluster(db)
    if prior:
        stats.from_prior = _restore_original_claims(db, claims, prior)

    db.execute("BEGIN")
    try:
        db.execute("DELETE FROM resolution")
        times: dict[int, dict] = {}
        for cluster_id, fields in claims.items():
            stats.clusters += 1
            rows, when = _resolve_cluster(cluster_id, fields, suspect, stats)
            if when:
                times[cluster_id] = when
            for row in rows:
                _write(db, cluster_id, *row)
            if progress and stats.clusters % 500 == 0:
                progress(stats)
        _assign_zones(db, times, stats)
        if infer_location:
            _infer_locations(db, times, stats, radius_km=location_radius_km)
    finally:
        db.execute("COMMIT")
    if progress:
        progress(stats)
    return stats


# ------------------------------------------------------------------ loading


def _batch_timestamps(db) -> dict[str, int]:
    """Minutes so many unrelated assets share that they cannot be captures."""
    rows = db.execute("""
        SELECT substr(x.value, 1, 16) AS minute, COUNT(DISTINCT m.cluster_id) AS n
        FROM meta x JOIN member m ON m.file_id = x.file_id
        WHERE x.field = 'datetime_utc' AND x.source IN ('exif', 'quicktime', 'google_json')
        GROUP BY minute HAVING n >= ?""", (BATCH_MINUTE_CLUSTERS,)).fetchall()
    return {r["minute"]: r["n"] for r in rows}


def _claims_by_cluster(db) -> dict[int, dict[str, list[Claim]]]:
    out: dict[int, dict[str, list[Claim]]] = {}
    for r in db.execute("""
        SELECT m.cluster_id AS cid, x.field, x.value, x.source, x.confidence
        FROM member m JOIN meta x ON x.file_id = m.file_id
        ORDER BY m.cluster_id"""):
        out.setdefault(r["cid"], {}).setdefault(r["field"], []).append(
            Claim(r["value"], r["source"], r["confidence"]))
    return out


# ---------------------------------------------------------------- resolving


def _resolve_cluster(cluster_id, fields, suspect, stats):
    rows: list[tuple] = []
    when = _resolve_time(fields, suspect, stats, rows)
    _resolve_gps(fields, stats, rows)
    for name, sources in SIMPLE_FIELDS.items():
        best = _best_simple(fields.get(name, []), sources)
        if best:
            rows.append((name, best.value, best.source, best.confidence, None, ""))
    return rows, when


def _resolve_time(fields, suspect, stats, rows):
    # mtime is rank 9 and is evidence only when nothing else survives. Left in
    # the pool it disagrees with every real capture time by years — copying a
    # file resets it — and would mark the whole library as conflicted.
    pool = [c for c in fields.get("datetime_utc", []) if c.source != "fs"]
    manual = [c for c in pool if c.source == "manual"]
    if manual:
        pool = manual          # a hand-set date is not in competition with anything

    # A wall clock is evidence too. Ignoring it threw away the filename dates
    # that are the only correct claim for a file whose EXIF records a batch
    # re-save — 6,453 such claims across 4,111 assets in this library. It is
    # converted with the asset's own offset where there is one; without one the
    # value is still worth comparing, at a discount, since the error is bounded
    # by the widest timezone rather than by years.
    offset = _best_simple(fields.get("utc_offset", []), ("exif", "quicktime", "xmp"))
    shift = _offset_seconds(offset.value) if offset else 0
    # Only from a source that produced no true instant of its own. EXIF that
    # carries an offset already contributed the UTC value this would recompute,
    # and converting it a second time with a *borrowed* offset manufactures an
    # hour-scale disagreement out of two claims that never disagreed.
    have_instant = {c.source for c in pool}
    for c in fields.get("datetime_local", []):
        if c.source in have_instant:
            continue
        instant = _epoch(c.value)
        if instant is None:
            continue
        as_utc = datetime.fromtimestamp(instant - shift, timezone.utc).isoformat()
        pool.append(Claim(as_utc, c.source,
                          c.confidence * (1.0 if offset else LOCAL_PENALTY),
                          unanchored=offset is None))

    if not pool:
        pool = fields.get("datetime_utc", [])
        if pool:
            stats.bump("mtime was the only evidence of a date")
    claims = []
    for c in pool:
        instant = _epoch(c.value)
        unanchored = getattr(c, "unanchored", False)
        if instant is None:
            continue
        if datetime.fromtimestamp(instant, timezone.utc).year < EARLIEST_PLAUSIBLE:
            stats.bump("rejected a null timestamp read back as the Unix epoch")
            continue
        confidence = c.confidence
        # Google's `photoTakenTime` is read from the same EXIF, so it inherits
        # the same batch stamps: the 2018-12-30T15:14 minute covers 163 assets
        # via EXIF and another 165 via the sidecar.
        if c.source in ("exif", "quicktime", "google_json") and c.value[:16] in suspect:
            confidence *= BATCH_PENALTY
        claims.append(Claim(c.value, c.source, confidence, instant, unanchored))
    if not claims:
        stats.bump("no capture time at all")
        return None

    groups = _group_by_time(claims)
    chosen, note = _choose_time_group(groups, stats)
    if note:
        stats.bump(note.split(":")[0])
    best = max(chosen, key=lambda c: (c.confidence, -TIME_RANK.get(c.source, 9)))
    competing = [{"value": c.value, "source": c.source, "confidence": round(c.confidence, 3)}
                 for g in groups for c in g if g is not chosen]
    stats.resolved_time += 1
    rows.append(("datetime_utc", best.value, best.source, round(best.confidence, 3),
                 competing or None, note))

    if offset:
        stats.tz_from_offset += 1
        rows.append(("utc_offset", offset.value, offset.source, offset.confidence, None,
                     "from the file's own offset tag"))
    return {"instant": best.instant, "offset": offset.value if offset else None,
            "unanchored": best.unanchored}


def _group_by_time(claims: list[Claim]) -> list[list[Claim]]:
    """Claims within `AGREE_SECONDS` of each other are one claim (§4.1)."""
    groups: list[list[Claim]] = []
    for c in sorted(claims, key=lambda c: c.instant):
        if groups and c.instant - groups[-1][-1].instant <= AGREE_SECONDS:
            groups[-1].append(c)
        else:
            groups.append([c])
    return groups


def _choose_time_group(groups, stats):
    if len(groups) == 1:
        return groups[0], ""
    earliest, latest = groups[0], groups[-1]
    spread = latest[-1].instant - earliest[0].instant

    # A whole-hour gap is a timezone rendered two ways, not two capture times.
    if spread <= TZ_MAX_HOURS * 3600 and _near_whole_hour(spread):
        with_offset = [g for g in groups
                       if any(c.source in ("exif", "quicktime") for c in g)]
        picked = with_offset[0] if with_offset else earliest
        # §4.1 is explicit that this is not a conflict, so it is not counted as
        # one — otherwise the headline number says the library is in dispute
        # when it is merely being read in two zones.
        stats.tz_artifacts += 1
        return picked, "tz_resolved: whole-hour gap treated as a timezone artifact"

    # Otherwise the earliest plausible claim wins: re-saves move a timestamp
    # forward, never back. The alternatives stay in `competing`.
    stats.conflicts += 1
    if spread > REVIEW_SECONDS:
        stats.review += 1
        return earliest, (f"date_conflict: claims span {spread / 86400:.1f} days — "
                          f"kept the earliest, review before trusting it")
    return earliest, f"soft_conflict: claims span {spread / 60:.0f} min — kept the earliest"


def _near_whole_hour(seconds: float) -> bool:
    return abs(seconds % 3600) <= TZ_SLACK_SECONDS or abs(3600 - seconds % 3600) <= TZ_SLACK_SECONDS


def _resolve_gps(fields, stats, rows):
    """Latitude and longitude move together or not at all (D3)."""
    claims = [c for c in fields.get("gps", []) if _coords(c.value)]
    if not claims:
        return
    claims.sort(key=lambda c: (GPS_RANK.get(c.source, 9), -c.confidence))
    best = claims[0]
    note = ""
    far = [c for c in claims[1:]
           if _haversine(_coords(best.value), _coords(c.value)) > GPS_AGREE_KM]
    if far:
        worst = max(far, key=lambda c: _haversine(_coords(best.value), _coords(c.value)))
        km = _haversine(_coords(best.value), _coords(worst.value))
        if km >= GPS_REVIEW_KM:
            # §4.2: except that a camera's own fix beats a pin dropped by hand
            # in the Google UI, which is the one disagreement with a known cause.
            if best.source == "exif" and worst.source == "google_json":
                note = f"gps_conflict: {km:.1f} km from the sidecar; kept the camera's fix"
            else:
                note = f"gps_conflict: sources {km:.1f} km apart — review"
                stats.gps_review += 1
        else:
            note = f"gps_spread: sources {km * 1000:.0f} m apart"
        stats.bump(note.split(":")[0])
        stats.gps_conflicts += 1
    competing = [{"value": c.value, "source": c.source} for c in claims[1:]]
    stats.resolved_gps += 1
    rows.append(("gps", best.value, best.source, best.confidence, competing or None, note))
    altitude = _best_simple(fields.get("gps_altitude", []), ("exif", "quicktime", "google_json"))
    if altitude:
        rows.append(("gps_altitude", altitude.value, altitude.source,
                     altitude.confidence, None, ""))


def _best_simple(claims: list[Claim], sources) -> Claim | None:
    rank = {s: i for i, s in enumerate(sources)}
    usable = [c for c in claims if c.source in rank and c.value]
    if not usable:
        return None
    return min(usable, key=lambda c: (rank[c.source], -c.confidence, c.value))


# ------------------------------------------------------------------- zones


def _assign_zones(db, times, stats):
    """Fill the zone for assets that know an instant but not an offset.

    Rank 4 is the GPS-derived zone; rank 4b is the zone of the nearest asset in
    time that knows one. Measured on this library, 83% of the offset-less assets
    have such an anchor within six hours and 54% within a minute — the same
    capture session — which makes inheritance far safer than assuming a zone.
    """
    finder = _timezone_finder()
    anchors = sorted((v["instant"], v["offset"]) for v in times.values() if v["offset"])
    places = {r["cluster_id"]: r["value"] for r in db.execute(
        "SELECT cluster_id, value FROM resolution WHERE field = 'gps'")}

    for cluster_id, when in times.items():
        if when["offset"]:
            continue
        offset = None
        note = ""
        coords = _coords(places.get(cluster_id, ""))
        if coords and finder:
            zone = finder.timezone_at(lat=coords[0], lng=coords[1])
            if zone:
                offset = _offset_at(zone, when["instant"])
                note = f"tz from location ({zone})"
                stats.tz_from_gps += 1
        if offset is None and anchors:
            nearest = min(anchors, key=lambda a: abs(a[0] - when["instant"]))
            gap = abs(nearest[0] - when["instant"])
            offset = nearest[1]
            note = (f"tz inherited from the nearest dated photo "
                    f"({_describe_gap(gap)} away)")
            stats.tz_from_neighbour += 1
            if gap > 86400:
                note += " — wide gap, treat with suspicion"
        if offset:
            _write(db, cluster_id, "utc_offset", offset, "derived", 0.5, None, note)
            if when.get("unanchored"):
                # The chosen time was a wall clock read as UTC because no zone
                # was known yet. Now one is, so the instant has to move — left
                # alone the file would be filed and named hours out.
                shift = _offset_seconds(offset)
                anchored = datetime.fromtimestamp(
                    when["instant"] - shift, timezone.utc).isoformat()
                _write(db, cluster_id, "datetime_utc", anchored, "derived", 0.5, None,
                       f"wall clock re-anchored once the zone was known ({offset})")
                stats.reanchored += 1
        else:
            stats.tz_unknown += 1


def _infer_locations(db, times, stats, *, radius_km: float) -> None:
    """Give an unlocated asset the location of the rest of its day.

    Only when every located photo that day falls inside one city-sized radius:
    a day that spans a flight has no single answer, and this declines it rather
    than picking one. The value taken is the *nearest in time*, since the
    closest photo in time is the closest in place.

    This is an inference, not evidence, and it is the only field in the pipeline
    that is invented rather than harvested. It is therefore recorded at low
    confidence, noted in the report, and written into the output as
    `GPSProcessingMethod = ESTIMATED` — the standard EXIF field for exactly this
    — so no downstream tool mistakes a guess for a camera fix.
    """
    located: dict[str, list[tuple[float, tuple[float, float]]]] = {}
    unlocated: dict[str, list[tuple[float, int]]] = {}
    placed = {r["cluster_id"] for r in db.execute(
        "SELECT cluster_id FROM resolution WHERE field = 'gps'")}
    fixes = {r["cluster_id"]: _coords(r["value"]) for r in db.execute(
        "SELECT cluster_id, value FROM resolution WHERE field = 'gps'")}

    for cluster_id, when in times.items():
        instant = when.get("instant")
        if instant is None:
            continue
        shift = _offset_seconds(when.get("offset") or "+00:00")
        day = datetime.fromtimestamp(instant + shift, timezone.utc).date().isoformat()
        if cluster_id in placed:
            point = fixes.get(cluster_id)
            if point:
                located.setdefault(day, []).append((instant, point))
        else:
            unlocated.setdefault(day, []).append((instant, cluster_id))

    # Pass one: the travel bound. Nearest measured fix in time, accepted when
    # the distance you could have covered in that gap is small enough that the
    # answer still means something. Each inference carries its own radius
    # rather than sharing one global threshold.
    flat_anchors = sorted((t, p) for items in located.values() for t, p in items)
    anchor_times = [t for t, _ in flat_anchors]
    placed_now: set[int] = set()
    for day, wanting in unlocated.items():
        for instant, cluster_id in wanting:
            if not flat_anchors:
                break
            i = bisect.bisect_left(anchor_times, instant)
            best = None
            for j in (i - 1, i):
                if 0 <= j < len(flat_anchors):
                    gap = abs(flat_anchors[j][0] - instant)
                    if best is None or gap < best[0]:
                        best = (gap, flat_anchors[j][1])
            if best is None or best[0] > TRAVEL_MAX_MINUTES * 60:
                continue
            gap, (lat, lon) = best
            radius = gap / 3600.0 * TRAVEL_KMH
            _write(db, cluster_id, "gps", f"{lat:.7f},{lon:.7f}", "inferred", 0.35, None,
                   f"nearest located photo was {_describe_gap(gap)} away, so this is "
                   f"within about {radius:.0f} km of it")
            stats.gps_inferred += 1
            stats.gps_from_travel += 1
            placed_now.add(cluster_id)

    # Pass two: the stationary-day rule, for photos too far in time for the
    # travel bound but on a day that demonstrably never left one place.
    for day, wanting in unlocated.items():
        wanting = [(t, c) for t, c in wanting if c not in placed_now]
        if not wanting:
            continue
        anchors = located.get(day)
        if not anchors:
            stats.gps_no_anchor += len(wanting)
            continue
        points = [p for _, p in anchors]
        spread = max((_haversine(a, b) for i, a in enumerate(points)
                      for b in points[i + 1:]), default=0.0)
        if spread > radius_km:
            stats.gps_day_too_wide += len(wanting)
            continue
        first, last = min(a[0] for a in anchors), max(a[0] for a in anchors)
        for instant, cluster_id in wanting:
            nearest = min(anchors, key=lambda a: abs(a[0] - instant))
            gap = abs(nearest[0] - instant)
            inside = first <= instant <= last
            if len(anchors) == 1:
                budget = LONE_ANCHOR_HOURS * 3600
                basis = "a single located photo"
            elif inside:
                budget = float("inf")      # the day is demonstrably stationary here
                basis = f"{len(anchors)} located photos bracketing it"
            else:
                budget = OUTSIDE_SPAN_HOURS * 3600
                basis = f"{len(anchors)} located photos, all before or after it"
            if gap > budget:
                stats.gps_gap_too_wide += 1
                continue
            lat, lon = nearest[1]
            _write(db, cluster_id, "gps", f"{lat:.7f},{lon:.7f}", "inferred", 0.3, None,
                   f"inferred from {basis} the same day, all within {spread:.1f} km; "
                   f"nearest was {_describe_gap(gap)} away")
            stats.gps_inferred += 1


def _timezone_finder():
    try:
        from timezonefinder import TimezoneFinder
    except ImportError:
        return None
    return TimezoneFinder()


def _offset_at(zone: str, instant: float) -> str | None:
    try:
        from zoneinfo import ZoneInfo
        delta = datetime.fromtimestamp(instant, ZoneInfo(zone)).utcoffset()
    except Exception:
        return None
    if delta is None:
        return None
    total = int(delta.total_seconds())
    sign = "-" if total < 0 else "+"
    total = abs(total)
    return f"{sign}{total // 3600:02d}:{(total % 3600) // 60:02d}"


def _describe_gap(seconds: float) -> str:
    if seconds < 90:
        return f"{seconds:.0f} s"
    if seconds < 5400:
        return f"{seconds / 60:.0f} min"
    if seconds < 86400:
        return f"{seconds / 3600:.1f} h"
    return f"{seconds / 86400:.1f} days"


# ------------------------------------------------------------------ helpers


def _offset_seconds(offset: str) -> int:
    m = _OFFSET_RE.match((offset or "").strip())
    if not m:
        return 0
    sign = 1 if m.group(1) == "+" else -1
    return sign * (int(m.group(2)) * 3600 + int(m.group(3)) * 60)


def _epoch(value: str) -> float | None:
    """Seconds since the epoch, reading a naive value as UTC.

    `datetime.fromisoformat("...T11:48:17").timestamp()` silently interprets the
    value in the *machine's* timezone, which is D2 in a new place: the same
    catalog would resolve differently in Tokyo and in Chicago. Wall-clock claims
    are stored without a zone by design, so they must be anchored explicitly.
    """
    try:
        when = datetime.fromisoformat(value)
    except (ValueError, TypeError):
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return when.timestamp()


def _coords(value: str) -> tuple[float, float] | None:
    if not value:
        return None
    try:
        lat, _, lon = value.partition(",")
        return float(lat), float(lon)
    except ValueError:
        return None


def _haversine(one, two) -> float:
    import math
    if not one or not two:
        return 0.0
    lat1, lon1, lat2, lon2 = map(math.radians, (*one, *two))
    h = (math.sin((lat2 - lat1) / 2) ** 2
         + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2)
    return 6371.0 * 2 * math.asin(math.sqrt(h))


def _write(db, cluster_id, field_name, value, source, confidence, competing, note) -> None:
    db.execute(
        "INSERT OR REPLACE INTO resolution "
        "(cluster_id, field, value, source, confidence, competing_json) VALUES (?,?,?,?,?,?)",
        (cluster_id, field_name, value, source, confidence,
         json.dumps({"note": note, "competing": competing}, ensure_ascii=False)
         if (note or competing) else None))
