"""`explain` and `undo` — the two things that make a non-repeatable run survivable."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from photomerge.explain import explain
from photomerge.report_html import write_html
from photomerge.write import undo_write, write
from tests import fixtures
from tests.test_reclaim import dropped_file, library


def text(db, needle: str) -> str:
    return "\n".join(explain(db, needle))


def test_explain_says_which_asset_a_file_belongs_to_and_why(tmp_path):
    db = library(tmp_path)
    out = text(db, "IMG_0001")
    assert "identical bytes" in out                      # how they matched
    assert "canonical" in out and "duplicate" in out     # who won, who lost
    assert "ITS OWN CLAIMS" in out                       # the evidence
    assert "2024:11:27" in out or "2024-11-27" in out


def test_explain_finds_a_file_by_its_output_name(tmp_path):
    """Asked from the other direction: 'where did this output file come from?'"""
    db = library(tmp_path)
    write(db, tmp_path / "RESULT", apply=True)
    assert "IMG_0001" in text(db, "20241127_114817")


def test_explain_reports_whether_a_duplicate_is_safe_to_reclaim(tmp_path):
    db = library(tmp_path)
    before = text(db, str(dropped_file(db)))
    assert "will NOT be staged or unlinked" in before
    write(db, tmp_path / "RESULT", apply=True)
    after = text(db, str(dropped_file(db)))
    assert "verified, so this file may be reclaimed" in after


def test_explain_survives_the_pixels_being_gone(tmp_path):
    """The reason it reads from the catalog: after `reclaim` the evidence that
    justified a decision no longer exists, but the question still gets asked."""
    db = library(tmp_path)
    write(db, tmp_path / "RESULT", apply=True)
    victim = dropped_file(db)
    victim.unlink()
    out = text(db, victim.name)
    assert "DECISION" in out and "duplicate" in out


def test_explain_says_so_when_nothing_matches(tmp_path):
    db = library(tmp_path)
    assert "nothing in the catalog matches" in text(db, "no_such_file_xyz")


# ------------------------------------------------------------------- undo


def test_undo_removes_copies_and_leaves_the_sources_alone(tmp_path):
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    write(db, out, apply=True)
    written = sorted(p for p in out.rglob("*.*") if p.suffix in (".jpg", ".mov"))
    assert written

    stats = undo_write(db, out, apply=True)
    assert stats.deleted == len(written) and stats.failures == []
    assert not [p for p in out.rglob("*.*") if p.suffix in (".jpg", ".mov")]
    # Copy mode never touched the sources, so they are all still there.
    assert list((tmp_path / "mac").glob("*.jpg"))


def test_undo_puts_moved_files_back(tmp_path):
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    sources = {r[0] for r in db.execute(
        "SELECT f.path FROM member m JOIN file f ON f.id=m.file_id "
        "WHERE m.role IN ('canonical','companion')")}
    write(db, out, apply=True, move=True)
    assert not any(Path(p).exists() for p in sources), "move emptied the sources"

    stats = undo_write(db, out, apply=True)
    assert stats.reversed == len(sources) and stats.failures == []
    assert all(Path(p).exists() for p in sources), "and undo brought them back"


def test_undo_refuses_to_overwrite_and_refuses_to_orphan(tmp_path):
    """Two ways an undo could destroy something, both declined."""
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    write(db, out, apply=True, move=True)
    # Something else now occupies the original path.
    original = Path(next(r[0] for r in db.execute(
        "SELECT f.path FROM member m JOIN file f ON f.id=m.file_id "
        "WHERE m.role='canonical'")))
    original.parent.mkdir(parents=True, exist_ok=True)
    original.write_bytes(b"something else")
    stats = undo_write(db, out, apply=True)
    assert "its original path is occupied again" in stats.reasons
    assert original.read_bytes() == b"something else"


def test_undo_clears_the_verification_stamps(tmp_path):
    """Otherwise `trash` would still believe a replacement exists that does not,
    and would happily stage the file it replaced."""
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    write(db, out, apply=True)
    assert db.execute(
        "SELECT COUNT(*) FROM decision WHERE verified_at IS NOT NULL").fetchone()[0]
    undo_write(db, out, apply=True)
    assert db.execute(
        "SELECT COUNT(*) FROM decision WHERE verified_at IS NOT NULL").fetchone()[0] == 0


def test_a_dry_run_undo_changes_nothing(tmp_path):
    db = library(tmp_path)
    out = tmp_path / "RESULT"
    write(db, out, apply=True)
    before = sorted(p.name for p in out.rglob("*.*"))
    undo_write(db, out, apply=False)
    assert sorted(p.name for p in out.rglob("*.*")) == before


# ------------------------------------------------------------- html report


def test_the_html_report_leads_with_coverage_before_and_after(tmp_path):
    db = library(tmp_path)
    page = write_html(db, tmp_path / "report.html").read_text(encoding="utf-8")
    assert "Metadata coverage" in page and "before" in page and "after" in page
    assert "A capture time" in page and "A location" in page
    # Self-contained: no network, so it renders the same in ten years.
    assert "http://" not in page and "https://" not in page
    assert "input files" in page and "reclaimable" in page
