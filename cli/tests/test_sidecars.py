"""The Takeout sidecar cascade and what a sidecar is allowed to claim."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from photomerge.sidecars import (
    DirIndex, find_sidecars, parse_google_json, strip_google_decoration,
)
from tests import fixtures


def rule_for(media: Path) -> str | None:
    hits = [h for h in find_sidecars(media, DirIndex()) if h[0] == "google_json"]
    return hits[0][2] if hits else None


def test_plain_supplemental_metadata(tmp_path):
    media = fixtures.write_jpeg(tmp_path / "PXL_20241127_164817540.jpg")
    fixtures.write_takeout_sidecar(media, taken_epoch=1732726097)
    assert rule_for(media) == "exact"


def test_collision_suffix_on_the_media_name(tmp_path):
    # IMG_0088 (1).jpeg -> IMG_0088 (1).jpeg.supplemental-metadata.json
    media = fixtures.write_jpeg(tmp_path / "IMG_0088 (1).jpeg")
    fixtures.write_takeout_sidecar(media, taken_epoch=1732726097)
    assert rule_for(media) == "exact"


def test_collision_suffix_on_the_sidecar_stem(tmp_path):
    # IMG_0899(1).HEIC -> IMG_0899.HEIC.supplemental-metadata(1).json
    media = fixtures.write_jpeg(tmp_path / "IMG_0899(1).HEIC")
    fixtures.write_takeout_sidecar(
        media, taken_epoch=1732726097,
        name="IMG_0899.HEIC.supplemental-metadata(1).json",
    )
    assert rule_for(media) == "suffix_n"


def test_extension_case_need_not_agree(tmp_path):
    # The real export pairs IMG_0460.MOV with a sidecar written against `.mov`.
    media = fixtures.write_mov(tmp_path / "IMG_0460(1).MOV")
    fixtures.write_takeout_sidecar(
        media, taken_epoch=1732726097,
        name="IMG_0460.mov.supplemental-metadata(1).json",
    )
    assert rule_for(media) == "suffix_n"


def test_extensionless_media_matches_on_its_stem(tmp_path):
    media = fixtures.write_mov(tmp_path / "IMG_7747")
    fixtures.write_takeout_sidecar(
        media, taken_epoch=1732726097, name="IMG_7747.MOV.supplemental-metadata.json"
    )
    assert rule_for(media) == "stem"


def test_an_edit_inherits_from_its_origin(tmp_path):
    origin = fixtures.write_jpeg(tmp_path / "PXL_20241229_011829042.jpg")
    fixtures.write_takeout_sidecar(origin, taken_epoch=1732726097)
    edit = fixtures.write_jpeg(tmp_path / "PXL_20241229_011829042-edited.jpg")
    assert rule_for(edit) == "edited_origin"


def test_a_tilde_copy_is_not_an_edit_marker(tmp_path):
    # `NAME~2-edited.jpg` inherits from `NAME~2.jpg`, not from `NAME.jpg`.
    # Stripping `~2` too was the only thing the cascade missed on the real export.
    real = fixtures.write_jpeg(tmp_path / "original_x_IMG_0752~2.jpg")
    fixtures.write_takeout_sidecar(real, taken_epoch=111111111)
    decoy = fixtures.write_jpeg(tmp_path / "original_x_IMG_0752.jpg")
    fixtures.write_takeout_sidecar(decoy, taken_epoch=999999999)
    edit = fixtures.write_jpeg(tmp_path / "original_x_IMG_0752~2-edited.jpg")
    hits = [h for h in find_sidecars(edit, DirIndex()) if h[0] == "google_json"]
    assert hits and hits[0][1].name.startswith("original_x_IMG_0752~2.jpg")


def test_no_sidecar_is_not_an_error(tmp_path):
    media = fixtures.write_jpeg(tmp_path / "IMG_0001.jpg")
    assert rule_for(media) is None


def test_null_island_means_no_location_but_the_equator_survives():
    # D5: `if lat or lon` rejected legitimate equator / prime-meridian fixes.
    def gps(lat, lon):
        block = {"latitude": lat, "longitude": lon, "altitude": 0.0}
        payload = {"photoTakenTime": {"timestamp": "1732726097"},
                   "geoDataExif": block, "geoData": block}
        return [(c[0], c[1]) for c in parse_google_json(payload) if c[0] == "gps"]

    assert gps(0.0, 0.0) == []                          # Google's "no location" sentinel
    assert gps(0.0, 12.5) == [("gps", "0.0,12.5")]      # on the equator
    assert gps(45.0, 0.0) == [("gps", "45.0,0.0")]      # on the prime meridian


def test_the_cameras_own_fix_is_preferred_over_the_hand_edited_one():
    """§4.2 — `geoDataExif` is what the camera recorded; `geoData` may have been
    typed into the Google UI. They agree in every sidecar in this export, so the
    order is for other people's."""
    payload = {"photoTakenTime": {"timestamp": "1732726097"},
               "geoDataExif": {"latitude": 1.0, "longitude": 2.0},
               "geoData": {"latitude": 9.0, "longitude": 9.0}}
    gps = [c for c in parse_google_json(payload) if c[0] == "gps"]
    assert gps == [("gps", "1.0,2.0", 0.9)]


def test_gps_is_one_atomic_claim():
    # D3: lat and lon borrowed independently can assemble a coordinate out of
    # two different photos.  A record with only a latitude yields nothing.
    payload = {"photoTakenTime": {"timestamp": "1732726097"},
               "geoData": {"latitude": 38.89, "altitude": 3.0}}
    assert [c for c in parse_google_json(payload) if c[0].startswith("gps")] == []


def test_takeout_time_is_a_utc_instant_not_a_local_one():
    # D2: v0 converted to the machine's zone and dropped the tzinfo, so the same
    # library produced different dates depending on where it was merged.
    claims = dict((f, v) for f, v, _ in parse_google_json(
        {"photoTakenTime": {"timestamp": "1732726097"}}))
    assert claims["datetime_utc"] == "2024-11-27T16:48:17+00:00"


def test_capture_stem_collapses_googles_decorations():
    for name, want in [
        ("original_eb670b22-bc77-4b1f-b1fd-73321609212c_IMG_0752~2-edited.jpg", "IMG_0752"),
        ("IMG_0899(1).HEIC", "IMG_0899"),
        ("IMG_0088 (1).jpeg", "IMG_0088"),
        ("PXL_20241212_142659379.MP.jpg", "PXL_20241212_142659379"),
    ]:
        assert strip_google_decoration(name) == want
