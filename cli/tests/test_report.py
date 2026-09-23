"""The dry-run report — one row per input file, and the arithmetic must close."""

from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from photomerge.cluster import cluster
from photomerge.report import write_report
from tests import fixtures
from tests.test_cluster import catalog_for


def library(tmp_path: Path):
    image = fixtures.noise_image()
    mac, goog = tmp_path / "mac", tmp_path / "gphotos"
    original = fixtures.write_jpeg(mac / "IMG_1.jpg", image)
    fixtures.exiftool_set(
        original,
        "-EXIF:DateTimeOriginal=2024:11:27 11:48:17",
        "-EXIF:OffsetTimeOriginal=-05:00",
        "-EXIF:GPSLatitude=38.8911472", "-EXIF:GPSLatitudeRef=N",
        "-EXIF:GPSLongitude=77.0168083", "-EXIF:GPSLongitudeRef=W",
    )
    fixtures.write_jpeg(mac / "IMG_2.jpg", fixtures.noise_image(seed=7))
    goog.mkdir(parents=True)
    (goog / "IMG_1.jpg").write_bytes(original.read_bytes())   # an exact duplicate
    fixtures.write_mov(goog / "IMG_1.mov")                     # its Live Photo half

    db = catalog_for(tmp_path, [mac, goog])
    cluster(db)
    return db, write_report(db, tmp_path / "out")


def test_every_input_file_gets_exactly_one_row(tmp_path):
    db, stats = library(tmp_path)
    rows = list(csv.DictReader(open(stats.csv_path, encoding="utf-8")))
    assert len(rows) == stats.rows
    assert len(rows) == db.execute(
        "SELECT COUNT(*) FROM file WHERE status='extracted'").fetchone()[0]
    assert len({r["path"] for r in rows}) == len(rows)


def test_kept_and_dropped_account_for_every_byte(tmp_path):
    db, stats = library(tmp_path)
    rows = list(csv.DictReader(open(stats.csv_path, encoding="utf-8")))
    total = sum(int(r["size"]) for r in rows)
    assert stats.kept_bytes + stats.photo_freed + stats.video_freed == total


def test_a_files_own_claims_are_reported_unresolved(tmp_path):
    """Stage 4 has not run, so the report says what each file claims about
    itself and names the evidence — it never shows a resolved-looking value."""
    _, stats = library(tmp_path)
    rows = {r["rel_path"]: r for r in
            csv.DictReader(open(stats.csv_path, encoding="utf-8"))}
    original = rows["IMG_1.jpg"]
    assert original["datetime_from"] == "exif"
    assert original["own_datetime"].startswith("2024-11-27T16:48:17")
    lat, lon = (float(x) for x in original["own_gps"].split(","))
    assert round(lat, 4) == 38.8911 and round(lon, 4) == -77.0168
    # The movie has no EXIF of its own and must not borrow any here.
    assert rows["IMG_1.mov"]["own_gps"] == ""


def test_the_manifest_lists_what_would_be_kept_and_dropped(tmp_path):
    _, stats = library(tmp_path)
    manifest = json.loads(stats.manifest_path.read_text(encoding="utf-8"))
    assert manifest["assets"] == stats.assets
    assert len(manifest["clusters"]) == stats.assets
    merged = [c for c in manifest["clusters"] if c["drop"]]
    assert len(merged) == 1
    assert merged[0]["keep"]["path"].endswith("IMG_1.jpg")
    assert merged[0]["drop"][0]["reason"].startswith("same bytes as")
    assert merged[0]["companions"][0]["path"].endswith("IMG_1.mov")


def test_the_report_names_the_reason_for_every_merge(tmp_path):
    _, stats = library(tmp_path)
    for row in csv.DictReader(open(stats.csv_path, encoding="utf-8")):
        assert row["reason"], f"no reason recorded for {row['rel_path']}"
        assert row["kept"] in ("yes", "no")
