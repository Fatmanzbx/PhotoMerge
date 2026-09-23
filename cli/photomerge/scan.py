"""Stage 1 — walk the sources and record what is there.

Scan does no decoding and computes no hashes.  It establishes identity of *files*
(path, size, mtime, inode, type by magic bytes) and collects the evidence that
costs nothing more than a directory listing: sidecars, the filename, the folder.

Re-running is cheap and safe.  A file whose `(path, size, mtime, inode)` is
unchanged keeps its row and its extracted hashes; only new and modified files are
reconsidered.
"""

from __future__ import annotations

import os
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from photomerge import filenames, sidecars
from photomerge.sniff import sniff

# Names that are never media, whatever their bytes say.
SKIP_NAMES = {".ds_store", "thumbs.db", "desktop.ini", ".localized", "metadata.json",
              # Export-tool bookkeeping that lands inside the source tree.
              ".osxphotos_export.db", ".osxphotos_export.db-wal",
              ".osxphotos_export.db-shm"}
SKIP_PREFIXES = ("._",)
SKIP_SUFFIXES = (".json", ".xmp", ".aae", ".txt", ".html", ".csv", ".pdf")


@dataclass
class ScanStats:
    seen: int = 0
    added: int = 0
    updated: int = 0
    unchanged: int = 0
    repriced: int = 0
    skipped: int = 0
    by_kind: dict[str, int] = field(default_factory=dict)
    by_skip_reason: dict[str, int] = field(default_factory=dict)
    # Per source: a global rate is meaningless when one source ships sidecars
    # for everything and another ships none by design.
    sidecar_hit: dict[str, int] = field(default_factory=dict)
    sidecar_total: dict[str, int] = field(default_factory=dict)
    by_rule: dict[str, int] = field(default_factory=dict)

    def bump(self, bucket: dict[str, int], key: str) -> None:
        bucket[key] = bucket.get(key, 0) + 1


def scan(
    db: sqlite3.Connection,
    sources: list[Path],
    *,
    force: bool = False,
    progress=None,
) -> ScanStats:
    stats = ScanStats()
    index = sidecars.DirIndex()
    db.execute("BEGIN")
    try:
        for priority, root in enumerate(sources):
            root = Path(root).expanduser().resolve()
            if not root.is_dir():
                raise SystemExit(f"source is not a directory: {root}")
            stats.sidecar_total.setdefault(root.name, 0)
            stats.sidecar_hit.setdefault(root.name, 0)
            for path in _walk(root):
                stats.seen += 1
                if progress and stats.seen % 500 == 0:
                    progress(stats)
                _consider(db, stats, index, path, root, priority, force)
                if stats.seen % 2000 == 0:
                    db.execute("COMMIT")
                    db.execute("BEGIN")
    finally:
        db.execute("COMMIT")
    if progress:
        progress(stats)
    return stats


def _walk(root: Path):
    """Depth-first, name-sorted: the same library always scans in the same order."""
    for dirpath, dirnames, names in os.walk(root, followlinks=False):
        dirnames.sort()
        d = Path(dirpath)
        for name in sorted(names):
            yield d / name


def _consider(db, stats, index, path, root, priority, force) -> None:
    name = path.name
    low = name.casefold()
    if low in SKIP_NAMES or low.startswith(SKIP_PREFIXES) or low.endswith(SKIP_SUFFIXES):
        return  # Not media and not an error — sidecars are reached through their media.

    try:
        st = path.lstat()
    except OSError as exc:
        _record_skip(db, path, root, priority, 0, 0.0, f"stat failed: {exc}")
        stats.skipped += 1
        stats.bump(stats.by_skip_reason, "stat failed")
        return
    if not os.path.isfile(path) or os.path.islink(path):
        return
    if st.st_size == 0:
        _record_skip(db, path, root, priority, 0, st.st_mtime, "zero-byte file")
        stats.skipped += 1
        stats.bump(stats.by_skip_reason, "zero-byte file")
        return

    row = db.execute(
        "SELECT id, size, mtime, inode, status, source, source_priority "
        "FROM file WHERE path = ?", (str(path),)
    ).fetchone()
    unchanged = (
        row is not None
        and row["size"] == st.st_size
        and abs(row["mtime"] - st.st_mtime) < 1e-6
        and row["inode"] == st.st_ino
    )
    if unchanged and not force:
        stats.unchanged += 1
        stats.bump(stats.by_kind, row["status"])
        # The bytes are the same, but the caller may have reordered --src.
        # Priority is only a tiebreak, yet silently keeping a stale one would
        # make a reordering look applied when it was not.
        if (row["source"], row["source_priority"]) != (root.name, priority):
            db.execute(
                "UPDATE file SET source = ?, source_priority = ? WHERE id = ?",
                (root.name, priority, row["id"]))
            stats.repriced += 1
        return

    try:
        with open(path, "rb") as f:
            head = f.read(4096)
    except OSError as exc:
        _record_skip(db, path, root, priority, st.st_size, st.st_mtime, f"unreadable: {exc}")
        stats.skipped += 1
        stats.bump(stats.by_skip_reason, "unreadable")
        return

    kind, mime = sniff(path, head)
    if kind not in ("image", "video"):
        reason = f"unrecognised type ({mime or 'no magic'})"
        _record_skip(db, path, root, priority, st.st_size, st.st_mtime, reason)
        stats.skipped += 1
        stats.bump(stats.by_skip_reason, reason)
        return

    file_id = _upsert(db, path, root, priority, st, kind, mime)
    if row is None:
        stats.added += 1
    else:
        stats.updated += 1
    stats.bump(stats.by_kind, kind)
    _record_path_evidence(db, stats, index, file_id, path, root, st)


def _upsert(db, path, root, priority, st, kind, mime) -> int:
    now = datetime.now(timezone.utc).isoformat()
    db.execute(
        """
        INSERT INTO file (path, rel_path, source, source_priority, size, mtime,
                          inode, ext, kind, mime, status, error, scanned_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,'scanned',NULL,?)
        ON CONFLICT(path) DO UPDATE SET
            rel_path=excluded.rel_path, source=excluded.source,
            source_priority=excluded.source_priority, size=excluded.size,
            mtime=excluded.mtime, inode=excluded.inode, ext=excluded.ext,
            kind=excluded.kind, mime=excluded.mime, status='scanned', error=NULL,
            scanned_at=excluded.scanned_at,
            -- the bytes changed, so everything derived from them is stale
            sha256=NULL, pixel_hash=NULL, dhash64=NULL, phash256=NULL,
            width=NULL, height=NULL, sharpness=NULL, make=NULL, model=NULL,
            exposure_key=NULL, content_id=NULL, extracted_at=NULL
        """,
        (str(path), str(path.relative_to(root)), root.name, priority, st.st_size,
         st.st_mtime, st.st_ino, path.suffix.lower(), kind, mime, now),
    )
    return db.execute("SELECT id FROM file WHERE path = ?", (str(path),)).fetchone()["id"]


def _record_skip(db, path, root, priority, size, mtime, reason) -> None:
    now = datetime.now(timezone.utc).isoformat()
    db.execute(
        """
        INSERT INTO file (path, rel_path, source, source_priority, size, mtime,
                          ext, kind, status, error, scanned_at)
        VALUES (?,?,?,?,?,?,?,'other','skipped',?,?)
        ON CONFLICT(path) DO UPDATE SET
            size=excluded.size, mtime=excluded.mtime, status='skipped',
            error=excluded.error, scanned_at=excluded.scanned_at
        """,
        (str(path), str(path.relative_to(root)), root.name, priority, size, mtime,
         path.suffix.lower(), reason, now),
    )


def _record_path_evidence(db, stats, index, file_id, path, root, st) -> None:
    """Claims available without opening the media: sidecars, name, folder, mtime."""
    db.execute("DELETE FROM meta WHERE file_id = ? AND source IN "
               "('google_json','filename','foldername','fs')", (file_id,))
    db.execute("DELETE FROM sidecar WHERE file_id = ?", (file_id,))
    claims: list[tuple[str, str, str, float]] = []

    found = sidecars.find_sidecars(path, index)
    stats.bump(stats.sidecar_total, root.name)
    if any(kind == "google_json" for kind, _, _ in found):
        stats.bump(stats.sidecar_hit, root.name)
    for kind, sidecar_path, rule in found:
        stats.bump(stats.by_rule, f"{kind}:{rule}")
        payload = sidecars.load(sidecar_path) if kind == "google_json" else None
        db.execute(
            "INSERT OR IGNORE INTO sidecar (file_id, kind, path, rule, payload_json) "
            "VALUES (?,?,?,?,?)",
            (file_id, kind, str(sidecar_path), rule,
             None if payload is None else _compact(payload)),
        )
        if payload is not None:
            confidence_scale = 0.6 if rule == "edited_origin" else 1.0
            for field_name, value, confidence in sidecars.parse_google_json(payload):
                claims.append((field_name, value, "google_json", confidence * confidence_scale))

    named = filenames.datetime_from_name(path.name)
    if named:
        claims.append((named[0], named[1], "filename", 0.5))
    claims.append(("capture_stem", sidecars.strip_google_decoration(path.name), "filename", 1.0))

    rel_parts = path.relative_to(root).parts[:-1]
    for field_name, value, confidence in filenames.folder_claims(rel_parts):
        claims.append((field_name, value, "foldername", confidence))

    # mtime is evidence of last resort.  Stage 4 must be able to see that a date
    # came from here and escalate rather than quietly file the photo under it (D11).
    claims.append(("datetime_utc",
                   datetime.fromtimestamp(st.st_mtime, timezone.utc).isoformat(),
                   "fs", 0.05))

    db.executemany(
        "INSERT INTO meta (file_id, field, value, source, confidence) VALUES (?,?,?,?,?)",
        [(file_id, f, v, s, c) for f, v, s, c in claims],
    )


def _compact(payload: dict) -> str:
    import json
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
