"""Staging and unlinking — the only code here that destroys anything.

Every test is written against one invariant (PLAN §5b): a file is staged or
unlinked only once the decision that replaces it carries `verified_at`. The
failure worth preventing is a duplicate being deleted while its replacement is
missing, unwritten or corrupt.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from photomerge.catalog import open_catalog
from photomerge.cluster import cluster
from photomerge.extract import extract
from photomerge.reclaim import TRASH, reclaim, restore, stage
from photomerge.resolve import resolve
from photomerge.scan import scan
from photomerge.write import write
from tests import fixtures


def library(tmp_path: Path):
    """One photo in two places, so exactly one file is superseded."""
    image = fixtures.photo_image()
    mac, goog = tmp_path / "mac", tmp_path / "gphotos"
    original = fixtures.write_jpeg(mac / "IMG_0001.jpg", image)
    fixtures.exiftool_set(original, "-EXIF:DateTimeOriginal=2024:11:27 11:48:17",
                          "-EXIF:OffsetTimeOriginal=-05:00")
    goog.mkdir(parents=True)
    (goog / "IMG_0001.jpg").write_bytes(original.read_bytes())

    db = open_catalog(tmp_path / "catalog.sqlite")
    scan(db, [mac, goog])
    extract(db, workers=2)
    cluster(db)
    resolve(db)
    return db


def dropped_file(db) -> Path:
    return Path(db.execute(
        "SELECT f.path FROM decision d JOIN file f ON f.id = d.file_id "
        "WHERE d.outcome = 'duplicate'").fetchone()["path"])


def test_nothing_is_staged_before_the_replacement_is_written(tmp_path):
    db = library(tmp_path)
    stats = stage(db, tmp_path / "RESULT", apply=True)
    assert stats.staged == 0
    assert stats.blocked == 1
    assert dropped_file(db).exists(), "the duplicate must still be there"


def test_nothing_is_staged_if_verification_was_skipped(tmp_path):
    """`--no-verify` leaves `verified_at` unset, and that alone must block the
    delete path — the gate is the catalog, not the running order."""
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    write(db, out, apply=True, verify=False)
    stats = stage(db, out, apply=True)
    assert stats.staged == 0 and stats.blocked == 1
    assert dropped_file(db).exists()


def test_staging_moves_the_duplicate_and_leaves_the_original_readable(tmp_path):
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    write(db, out, apply=True)
    victim = dropped_file(db)
    stats = stage(db, out, apply=True)
    assert stats.staged == 1 and stats.blocked == 0
    assert not victim.exists()
    staged = list((out / TRASH).rglob("*.jpg"))
    assert len(staged) == 1
    # The kept file is untouched and still the photo.
    assert list(out.rglob("2024/11/*.jpg"))


def test_restore_undoes_staging(tmp_path):
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    write(db, out, apply=True)
    victim = dropped_file(db)
    stage(db, out, apply=True)
    assert not victim.exists()
    assert restore(db, out, apply=True) == 1
    assert victim.exists(), "the review window is only real if it can be used"


def test_reclaim_reports_without_confirm_and_deletes_nothing(tmp_path):
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    write(db, out, apply=True)
    stage(db, out, apply=True)
    stats = reclaim(db, out, confirm=False)
    assert stats.files == 1 and stats.bytes_freed > 0
    assert list((out / TRASH).rglob("*.jpg")), "still there without --confirm"


def test_reclaim_with_confirm_unlinks(tmp_path):
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    write(db, out, apply=True)
    stage(db, out, apply=True)
    stats = reclaim(db, out, confirm=True)
    assert stats.files == 1 and stats.failures == []
    assert not list((out / TRASH).rglob("*.jpg"))
    # ... and what it replaced is still there.
    assert list(out.rglob("2024/11/*.jpg"))


def test_the_ledger_records_what_was_staged_and_what_replaced_it(tmp_path):
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    write(db, out, apply=True)
    stage(db, out, apply=True)
    ledger = json.loads((out / TRASH / "trash_ledger.json").read_text())
    entry = ledger["entries"][0]
    assert entry["from"].endswith("IMG_0001.jpg")
    assert entry["replaced_by"].endswith(".jpg")


def test_staging_is_idempotent(tmp_path):
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    write(db, out, apply=True)
    first = stage(db, out, apply=True)
    second = stage(db, out, apply=True)
    assert first.staged == 1
    assert second.staged == 0 and second.missing == 1


def test_reclaim_on_an_empty_trash_is_harmless(tmp_path):
    db = library(tmp_path)
    stats = reclaim(db, tmp_path / "RESULT", confirm=True)
    assert stats.files == 0 and stats.failures == []
