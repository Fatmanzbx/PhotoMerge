"""Stage 5b — staging superseded files, then unlinking them.

Two separate, deliberate steps (PLAN §5b):

    trash    — rename every superseded file into `RESULT/.trash/`, preserving
               its source-relative path. A same-volume rename is atomic and
               free, so this buys a review window without buying disk.
    reclaim  — unlink `.trash/`. Irreversible, and the only step that is.

The gate between them is the catalog, not the running order. A file is staged or
unlinked **only if the decision that replaces it carries `verified_at`** — set by
stage 5 when it re-read the written file and confirmed its pixels hash to the
source's and its tags read back. So "delete the duplicate" cannot happen unless
"the replacement is provably good" already has.

The cost of move mode, stated plainly: once `.trash/` is gone the analysis is
non-repeatable. Re-clustering at a different threshold needs the pixels, and they
will not be there. Review the contact sheets *before* this, not after.
"""

from __future__ import annotations

import json
import shutil
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

TRASH = ".trash"
LEDGER = "trash_ledger.json"


@dataclass
class TrashStats:
    eligible: int = 0
    blocked: int = 0
    staged: int = 0
    bytes_staged: int = 0
    missing: int = 0
    failures: list[str] = field(default_factory=list)
    blocked_reasons: dict[str, int] = field(default_factory=dict)

    def block(self, why: str) -> None:
        self.blocked += 1
        self.blocked_reasons[why] = self.blocked_reasons.get(why, 0) + 1


@dataclass
class ReclaimStats:
    files: int = 0
    bytes_freed: int = 0
    failures: list[str] = field(default_factory=list)


def stage(db: sqlite3.Connection, out_dir: Path, *, apply: bool = False) -> TrashStats:
    stats = TrashStats()
    trash = out_dir / TRASH
    rows = db.execute("""
        SELECT d.id, d.outcome, d.superseded_by, f.path, f.rel_path, f.source, f.size,
               k.verified_at AS keeper_verified, k.target_path AS keeper_target
        FROM decision d
        JOIN file f ON f.id = d.file_id
        LEFT JOIN decision k ON k.id = d.superseded_by
        WHERE d.outcome IN ('duplicate', 'burst_sibling')
        ORDER BY f.path""").fetchall()

    ledger: list[dict] = []
    for r in rows:
        if r["superseded_by"] is None:
            stats.block("no replacement recorded — run `write` first")
            continue
        if not r["keeper_verified"]:
            # The invariant. Not an execution-order detail: this is the whole
            # reason unlinking is allowed at all.
            stats.block("its replacement has not been written and verified")
            continue
        source = Path(r["path"])
        if not source.exists():
            stats.missing += 1
            continue
        stats.eligible += 1
        destination = trash / r["source"] / r["rel_path"]
        if not apply:
            continue
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(source), str(destination))
        except OSError as exc:
            stats.failures.append(f"{source}: {exc}")
            continue
        stats.staged += 1
        stats.bytes_staged += r["size"] or 0
        ledger.append({"from": str(source), "to": str(destination),
                       "size": r["size"], "replaced_by": r["keeper_target"]})

    if apply and ledger:
        _append_ledger(trash, ledger)
    return stats


def reclaim(db: sqlite3.Connection, out_dir: Path, *, confirm: bool = False) -> ReclaimStats:
    """Unlink the staged files. Irreversible."""
    stats = ReclaimStats()
    trash = out_dir / TRASH
    if not trash.is_dir():
        return stats
    for path in sorted(p for p in trash.rglob("*") if p.is_file() and p.name != LEDGER):
        try:
            size = path.stat().st_size
        except OSError:
            continue
        stats.files += 1
        stats.bytes_freed += size
        if not confirm:
            continue
        try:
            path.unlink()
        except OSError as exc:
            stats.failures.append(f"{path}: {exc}")
    if confirm:
        for directory in sorted((p for p in trash.rglob("*") if p.is_dir()),
                                key=lambda p: -len(p.parts)):
            try:
                directory.rmdir()
            except OSError:
                pass
    return stats


def restore(db: sqlite3.Connection, out_dir: Path, *, apply: bool = False) -> int:
    """Put everything in `.trash/` back where it came from.

    The review window is only real if it can actually be used, and that means
    being able to change your mind before `reclaim`.
    """
    trash = out_dir / TRASH
    ledger_path = trash / LEDGER
    if not ledger_path.exists():
        return 0
    entries = json.loads(ledger_path.read_text(encoding="utf-8")).get("entries", [])
    moved = 0
    for entry in entries:
        destination, source = Path(entry["from"]), Path(entry["to"])
        if not source.exists() or destination.exists():
            continue
        moved += 1
        if apply:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(source), str(destination))
    return moved


def _append_ledger(trash: Path, entries: list[dict]) -> None:
    path = trash / LEDGER
    existing = []
    if path.exists():
        try:
            existing = json.loads(path.read_text(encoding="utf-8")).get("entries", [])
        except ValueError:
            existing = []
    path.write_text(json.dumps({
        "updated": datetime.now(timezone.utc).isoformat(),
        "entries": existing + entries,
    }, ensure_ascii=False, indent=1), encoding="utf-8")
