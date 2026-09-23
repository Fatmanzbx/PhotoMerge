"""Stage 5 — naming, embedding, and the verification that makes it safe."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from photomerge.catalog import open_catalog
from photomerge.cluster import cluster
from photomerge.extract import extract
from photomerge.naming import extension_for, local_time, plan_targets
from photomerge.resolve import resolve
from photomerge.scan import scan
from photomerge.write import write
from tests import fixtures


# --------------------------------------------------------------- naming


def test_the_name_is_the_local_wall_clock_not_utc():
    assert local_time("2024-11-27T16:48:17+00:00", "-05:00").strftime("%Y%m%d_%H%M%S") \
        == "20241127_114817"


def test_the_extension_comes_from_the_detected_type_not_the_old_name():
    """This is what unifies .jpeg/.JPG and renames .MP to the container it is."""
    assert extension_for("image/jpeg", ".JPEG") == ".jpg"
    assert extension_for("image/heic", ".HEIC") == ".heic"
    assert extension_for("video/mp4", ".MP") == ".mp4"
    assert extension_for("video/quicktime", ".mp_original") == ".mov"


def test_a_live_photo_pair_shares_one_stem():
    targets = plan_targets([{
        "cluster_id": 1, "when": "2024-11-27T16:48:17+00:00", "offset": "-05:00",
        "members": [{"file_id": 1, "mime": "image/heic", "ext": ".HEIC", "role": "canonical"},
                    {"file_id": 2, "mime": "video/quicktime", "ext": ".MOV", "role": "companion"}],
    }])
    assert {t.relative for t in targets} == {
        "2024/11/20241127_114817.heic", "2024/11/20241127_114817.mov"}


def test_two_assets_in_one_second_do_not_collide():
    assets = [{"cluster_id": i, "when": "2024-11-27T16:48:17+00:00", "offset": "-05:00",
               "members": [{"file_id": i, "mime": "image/jpeg", "ext": ".jpg",
                            "role": "canonical"}]} for i in (1, 2, 3)]
    names = sorted(t.relative for t in plan_targets(assets))
    assert names == ["2024/11/20241127_114817.jpg", "2024/11/20241127_114817_1.jpg",
                     "2024/11/20241127_114817_2.jpg"]
    assert len(set(names)) == 3


def test_an_undated_asset_still_gets_a_home():
    targets = plan_targets([{"cluster_id": 7, "when": None, "offset": None,
                             "members": [{"file_id": 1, "mime": "image/jpeg",
                                          "ext": ".jpg", "role": "canonical"}]}])
    assert targets[0].relative.startswith("undated/")


# ------------------------------------------------------------ end to end


def library(tmp_path: Path):
    src = tmp_path / "mac"
    photo = fixtures.write_jpeg(src / "IMG_0001.JPEG", fixtures.photo_image())
    fixtures.exiftool_set(
        photo,
        "-EXIF:DateTimeOriginal=2024:11:27 11:48:17",
        "-EXIF:OffsetTimeOriginal=-05:00",
        "-EXIF:GPSLatitude=38.8911472", "-EXIF:GPSLatitudeRef=N",
        "-EXIF:GPSLongitude=77.0168083", "-EXIF:GPSLongitudeRef=W",
        "-EXIF:Make=Google", "-EXIF:Model=Pixel 9")
    movie = src / "IMG_0002.MOV"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "quiet", "-f", "lavfi",
                    "-i", "testsrc=duration=1:size=320x240:rate=10", "-c:v", "libx264",
                    "-pix_fmt", "yuv420p", "-f", "mov", str(movie)], check=True)
    fixtures.exiftool_set(movie, "-QuickTime:CreateDate=2024:11:27 16:48:20")

    db = open_catalog(tmp_path / "catalog.sqlite")
    scan(db, [src])
    extract(db, workers=2)
    cluster(db)
    resolve(db)
    return db


def test_a_dry_run_writes_nothing(tmp_path):
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    stats = write(db, out, apply=False)
    assert stats.files == 2 and stats.copied == 0
    assert not out.exists() or not any(out.rglob("*.jpg"))
    # ... but the plan is recorded, so it can be read before anything moves.
    targets = [r[0] for r in db.execute(
        "SELECT target_path FROM decision WHERE target_path IS NOT NULL")]
    assert any(t.endswith(".jpg") for t in targets)


def test_apply_writes_renames_and_embeds(tmp_path):
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    stats = write(db, out, apply=True)
    assert stats.failures == []
    assert stats.copied == 2 and stats.verified == 2

    written = sorted(p.relative_to(out).as_posix() for p in out.rglob("*.*")
                     if p.name != "manifest_write.json")
    assert written == ["2024/11/20241127_114817.jpg", "2024/11/20241127_114820.mov"]

    tags = json.loads(subprocess.run(
        ["exiftool", "-j", "-G", "-n", "-EXIF:DateTimeOriginal", "-EXIF:OffsetTimeOriginal",
         "-Composite:GPSLatitude", "-Composite:GPSLongitude", "-XMP:PreservedFileName",
         str(out / "2024/11/20241127_114817.jpg")],
        capture_output=True, text=True).stdout)[0]
    assert tags["EXIF:DateTimeOriginal"] == "2024:11:27 11:48:17"
    # D8: without the offset the output perpetuates the ambiguity.
    assert tags["EXIF:OffsetTimeOriginal"] == "-05:00"
    assert round(tags["Composite:GPSLongitude"], 4) == -77.0168
    # The only trail back to the source file.
    assert tags["XMP:PreservedFileName"] == "IMG_0001.JPEG"


def test_the_source_pixels_are_never_altered(tmp_path):
    """Copy, never re-encode. The written file must decode to the same pixels."""
    from photomerge.imagehash import open_oriented, pixel_hash

    db = library(tmp_path)
    out = tmp_path / "RESULT"
    write(db, out, apply=True)
    source = next((tmp_path / "mac").glob("IMG_0001.JPEG"))
    written = out / "2024/11/20241127_114817.jpg"
    with open_oriented(source) as a, open_oriented(written) as b:
        assert pixel_hash(a) == pixel_hash(b)


def test_writing_twice_is_idempotent(tmp_path):
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    write(db, out, apply=True)
    before = {p: p.stat().st_size for p in sorted(out.rglob("*.*"))}
    second = write(db, out, apply=True)
    assert second.copied == 0 and second.failures == []
    assert {p: p.stat().st_size for p in sorted(out.rglob("*.*"))} == before


def test_the_manifest_records_every_operation(tmp_path):
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    write(db, out, apply=True)
    manifest = json.loads((out / "manifest_write.json").read_text())
    assert manifest["files"] == 2 and manifest["verified"] == 2
    assert {Path(o["source"]).name for o in manifest["operations"]} == {
        "IMG_0001.JPEG", "IMG_0002.MOV"}
    assert all(o["action"] == "copy" and o["sha256"] for o in manifest["operations"])


def test_a_run_that_cannot_fit_is_refused_before_it_starts(tmp_path):
    import pytest

    db = library(tmp_path)
    from photomerge import write as W
    stats_path = tmp_path / "RESULT"
    real = W.shutil.disk_usage

    class Tiny:
        free = 1

    W.shutil.disk_usage = lambda _: Tiny()
    try:
        with pytest.raises(SystemExit, match="not enough space"):
            write(db, stats_path, apply=True)
    finally:
        W.shutil.disk_usage = real


def test_an_edit_is_written_beside_its_origin(tmp_path):
    """`_edited` rather than a bare `_1`, which would read as a name collision."""
    targets = plan_targets([{
        "cluster_id": 1, "when": "2024-11-27T16:48:17+00:00", "offset": "-05:00",
        "members": [{"file_id": 1, "mime": "image/jpeg", "ext": ".jpg",
                     "role": "canonical"},
                    {"file_id": 2, "mime": "image/jpeg", "ext": ".jpg",
                     "role": "variant"}],
    }])
    assert sorted(t.relative for t in targets) == [
        "2024/11/20241127_114817.jpg", "2024/11/20241127_114817_edited.jpg"]
