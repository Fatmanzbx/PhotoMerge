"""Scan and extract end to end on a built library."""

from __future__ import annotations

import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from photomerge.catalog import open_catalog
from photomerge.extract import extract
from photomerge.scan import scan
from tests import fixtures

# 2024-11-27 16:48:17 UTC — the instant every fixture below is taken at.
TAKEN_EPOCH = 1732726097
TAKEN_UTC = "2024-11-27T16:48:17+00:00"


def build_library(root: Path) -> Path:
    """One source with the shapes M1 has to survive."""
    src = root / "gphotos" / "Photos from 2024"

    # Camera original: EXIF date with an explicit offset, and a GPS fix.
    original = fixtures.write_jpeg(src / "PXL_20241127_114817540.jpg")
    fixtures.exiftool_set(
        original,
        "-EXIF:DateTimeOriginal=2024:11:27 11:48:17",
        "-EXIF:OffsetTimeOriginal=-05:00",
        "-EXIF:GPSLatitude=38.8911472", "-EXIF:GPSLatitudeRef=N",
        "-EXIF:GPSLongitude=77.0168083", "-EXIF:GPSLongitudeRef=W",
        "-EXIF:Make=Google", "-EXIF:Model=Pixel 9",
    )
    fixtures.write_takeout_sidecar(original, taken_epoch=TAKEN_EPOCH,
                                   lat=38.8911472, lon=-77.0168083)

    # Stripped copy: no EXIF at all (Pillow writes none), so the sidecar is the
    # only evidence there is.  The name also disagrees with the content, which is
    # ordinary in Takeout and must not derail anything.
    stripped = fixtures.write_jpeg(src / "IMG_0899(1).HEIC")
    fixtures.write_takeout_sidecar(
        stripped, taken_epoch=TAKEN_EPOCH, lat=38.8911472, lon=-77.0168083,
        name="IMG_0899.HEIC.supplemental-metadata(1).json",
    )

    # Extensionless QuickTime, dates in the container rather than in EXIF.
    movie = src / "IMG_7747"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "quiet", "-f", "lavfi",
         "-i", "testsrc=duration=1:size=320x240:rate=10",
         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-f", "mov", str(movie)],
        check=True,
    )
    fixtures.exiftool_set(movie, f"-QuickTime:CreateDate=2024:11:27 16:48:17")

    # Junk that must be skipped rather than counted or errored on.
    (src / ".DS_Store").write_bytes(b"\x00" * 16)
    (src / "empty.jpg").write_bytes(b"")
    return root / "gphotos"


def run(tmp_path: Path) -> sqlite3.Connection:
    source = build_library(tmp_path)
    db = open_catalog(tmp_path / "catalog.sqlite")
    scan(db, [source])
    extract(db, workers=2)
    return db


def claims(db, path_fragment: str, field: str) -> dict[str, str]:
    """`{source: value}` for one field of one file."""
    rows = db.execute(
        "SELECT m.source, m.value FROM meta m JOIN file f ON f.id = m.file_id "
        "WHERE f.path LIKE ? AND m.field = ?",
        (f"%{path_fragment}%", field),
    ).fetchall()
    return {r["source"]: r["value"] for r in rows}


def test_scan_classifies_by_content_and_skips_junk(tmp_path):
    db = run(tmp_path)
    kinds = dict(db.execute(
        "SELECT kind, COUNT(*) FROM file WHERE status='extracted' GROUP BY kind"))
    assert kinds == {"image": 2, "video": 1}
    # The extensionless file is a video despite having no suffix to go on (D13).
    row = db.execute("SELECT kind, mime FROM file WHERE path LIKE '%IMG_7747'").fetchone()
    assert (row["kind"], row["mime"]) == ("video", "video/quicktime")
    # `.DS_Store` is not recorded at all; a zero-byte file is, with a reason.
    assert db.execute("SELECT COUNT(*) FROM file WHERE path LIKE '%DS_Store'").fetchone()[0] == 0
    empty = db.execute("SELECT status, error FROM file WHERE path LIKE '%empty.jpg'").fetchone()
    assert empty["status"] == "skipped" and "zero-byte" in empty["error"]


def test_every_evidence_source_is_kept_side_by_side(tmp_path):
    db = run(tmp_path)
    # The camera original knows its own time; the sidecar agrees; mtime is also
    # recorded, but marked as the near-worthless evidence it is.
    got = claims(db, "PXL_20241127_114817540", "datetime_utc")
    assert got["exif"] == TAKEN_UTC
    assert got["google_json"] == TAKEN_UTC
    assert "fs" in got
    confidence = db.execute(
        "SELECT confidence FROM meta m JOIN file f ON f.id=m.file_id "
        "WHERE f.path LIKE '%PXL_20241127_114817540%' AND m.source='fs' "
        "AND m.field='datetime_utc'").fetchone()[0]
    assert confidence < 0.1


def test_a_stripped_copy_is_rescued_by_its_sidecar(tmp_path):
    """4% of the real library has no capture time except in the Takeout JSON."""
    db = run(tmp_path)
    got = claims(db, "IMG_0899(1)", "datetime_utc")
    assert "exif" not in got
    assert got["google_json"] == TAKEN_UTC
    assert claims(db, "IMG_0899(1)", "gps")["google_json"] == "38.8911472,-77.0168083"


def test_gps_is_signed_and_atomic(tmp_path):
    db = run(tmp_path)
    # Longitude is West: the sign must come back applied (v0 read the unsigned
    # EXIF tag), and latitude and longitude must arrive as one value (D3).
    value = claims(db, "PXL_20241127_114817540", "gps")["exif"]
    lat, lon = (float(x) for x in value.split(","))
    assert round(lat, 5) == 38.89115 and round(lon, 5) == -77.01681


def test_video_dates_come_from_the_container(tmp_path):
    db = run(tmp_path)
    assert claims(db, "IMG_7747", "datetime_utc")["quicktime"] == TAKEN_UTC


def test_rescanning_is_a_no_op_but_a_changed_file_is_reconsidered(tmp_path):
    source = build_library(tmp_path)
    db = open_catalog(tmp_path / "catalog.sqlite")
    scan(db, [source])
    extract(db, workers=2)

    again = scan(db, [source])
    assert (again.added, again.updated) == (0, 0)
    assert again.unchanged == 3

    # Touching the bytes invalidates everything derived from them.
    victim = next(source.rglob("PXL_*.jpg"))
    fixtures.write_jpeg(victim, fixtures.noise_image(seed=99))
    third = scan(db, [source])
    assert third.updated == 1
    row = db.execute("SELECT status, sha256 FROM file WHERE path=?", (str(victim),)).fetchone()
    assert row["status"] == "scanned" and row["sha256"] is None


@pytest.mark.parametrize("tz", ["Asia/Tokyo", "America/Chicago", "UTC"])
def test_the_catalog_does_not_depend_on_the_machines_timezone(tmp_path, tz):
    """D2, and PLAN §8's standing property.

    v0 rendered Takeout timestamps in the local zone and then dropped the tzinfo,
    so merging the same library in Tokyo and in Chicago filed photos under
    different days.  Every UTC instant in the catalog must be identical whatever
    `TZ` says.
    """
    source = build_library(tmp_path)
    catalog = tmp_path / f"{tz.replace('/', '_')}.sqlite"
    subprocess.run(
        [sys.executable, "-m", "photomerge", "-c", str(catalog),
         "scan", "--src", str(source)],
        cwd=ROOT, check=True, env=dict(os.environ, TZ=tz), capture_output=True,
    )
    subprocess.run(
        [sys.executable, "-m", "photomerge", "-c", str(catalog), "extract"],
        cwd=ROOT, check=True, env=dict(os.environ, TZ=tz), capture_output=True,
    )
    db = sqlite3.connect(catalog)
    db.row_factory = sqlite3.Row
    got = {
        (Path(r["path"]).name, r["source"]): r["value"]
        for r in db.execute(
            "SELECT f.path, m.source, m.value FROM meta m JOIN file f ON f.id=m.file_id "
            "WHERE m.field='datetime_utc' AND m.source != 'fs' ORDER BY f.path, m.source")
    }
    assert got == {
        ("PXL_20241127_114817540.jpg", "exif"): TAKEN_UTC,
        ("PXL_20241127_114817540.jpg", "google_json"): TAKEN_UTC,
        ("IMG_0899(1).HEIC", "google_json"): TAKEN_UTC,
        ("IMG_7747", "quicktime"): TAKEN_UTC,
    }


def test_reordering_src_updates_priority_without_rereading(tmp_path):
    """`--src` order is only a tiebreak, but a reordering that silently did not
    apply would be worse than one that costs a rescan."""
    source = build_library(tmp_path)
    other = tmp_path / "second"
    fixtures.write_jpeg(other / "only.jpg")

    db = open_catalog(tmp_path / "catalog.sqlite")
    scan(db, [source, other])
    assert db.execute("SELECT source_priority FROM file WHERE path LIKE '%only.jpg'"
                      ).fetchone()[0] == 1

    again = scan(db, [other, source])          # swapped
    assert again.unchanged == 4 and again.added == 0
    assert again.repriced == 4
    assert db.execute("SELECT source_priority FROM file WHERE path LIKE '%only.jpg'"
                      ).fetchone()[0] == 0
