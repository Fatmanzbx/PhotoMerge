"""Stage 5 — render the catalog into an output tree.

Nothing here happens without `--apply`. Without it the stage computes every
target path, records it, and stops, so the plan can be read before a byte moves.

Files are **copied, never re-encoded** (PLAN §5). Only the metadata block is
rewritten, which is why verification can be absolute: the written file's decoded
pixels must hash identically to the source's. A mismatch is a failed run, not a
warning.
"""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from photomerge import naming
from photomerge.exiftool import ExifTool
from photomerge.imagehash import open_oriented, pixel_hash

MANIFEST = "manifest_write.json"
BATCH = 80


@dataclass
class WriteStats:
    assets: int = 0
    files: int = 0
    bytes_needed: int = 0
    copied: int = 0
    cloned: int = 0
    moved: int = 0
    embedded: int = 0
    verified: int = 0
    failures: list[str] = field(default_factory=list)
    by_kind: dict[str, int] = field(default_factory=dict)
    applied: bool = False

    def bump(self, key: str) -> None:
        self.by_kind[key] = self.by_kind.get(key, 0) + 1


def write(
    db: sqlite3.Connection,
    out_dir: Path,
    *,
    apply: bool = False,
    move: bool = False,
    verify: bool = True,
    keep_bursts: bool = False,
    limit: int | None = None,
    progress=None,
) -> WriteStats:
    stats = WriteStats(applied=apply)
    assets, files = _gather(db, keep_bursts)
    targets = naming.plan_targets(assets)
    if limit:
        # Trial runs matter here: this is the first stage that touches anything
        # outside the catalog, and 20 files prove the pipeline as well as 10,000.
        keep = {t.cluster_id for t in targets[:limit]}
        targets = [t for t in targets if t.cluster_id in keep]
    stats.assets = len(assets)
    stats.files = len(targets)

    db.execute("BEGIN")
    try:
        for t in targets:
            db.execute("UPDATE decision SET target_path = ? WHERE file_id = ?",
                       (t.relative, t.file_id))
    finally:
        db.execute("COMMIT")

    stats.bytes_needed = sum(files[t.file_id]["size"] for t in targets)
    for t in targets:
        stats.bump(files[t.file_id]["kind"])
    if not apply:
        return stats

    _preflight(out_dir, stats, move)
    operations: list[dict] = []
    with ExifTool() as et:
        for start in range(0, len(targets), BATCH):
            batch = targets[start : start + BATCH]
            jobs = []
            for t in batch:
                source = files[t.file_id]
                destination = out_dir / t.relative
                if not _place(source["path"], destination, move, stats):
                    continue
                stats.moved if move else stats.copied
                fields, inferred = _resolution(db, t.cluster_id)
                tags = _tags(source, fields, gps_inferred=inferred)
                jobs.append((destination, tags))
                operations.append({
                    "source": source["path"], "target": str(destination),
                    "action": "move" if move else "copy", "sha256": source["sha256"],
                    "cluster": t.cluster_id, "role": t.role,
                })
            updated, output = et.write(jobs)
            stats.embedded += updated
            if verify:
                _record_verified(
                    db, _verify(et, jobs, files, targets[start : start + BATCH], stats))
            # Written after every batch, not at the end: in move mode a crash
            # halfway through leaves the sources partly renamed, and the manifest
            # is the only record of where everything went.
            _manifest(out_dir, operations, stats)
            if progress:
                progress(stats)

    link_superseded(db)
    _manifest(out_dir, operations, stats)
    return stats


# ------------------------------------------------------------------ gather


def _gather(db, keep_bursts: bool):
    roles = ("canonical", "companion", "variant") + (
        ("burst_sibling",) if keep_bursts else ())
    placeholders = ",".join("?" * len(roles))
    rows = db.execute(f"""
        SELECT m.cluster_id, m.role, f.id AS file_id, f.path, f.size, f.kind, f.mime,
               f.ext, f.sha256, f.pixel_hash, f.content_id
        FROM member m JOIN file f ON f.id = m.file_id
        WHERE m.role IN ({placeholders}) ORDER BY m.cluster_id""", roles).fetchall()

    resolved = {}
    for r in db.execute("SELECT cluster_id, field, value FROM resolution"):
        resolved.setdefault(r["cluster_id"], {})[r["field"]] = r["value"]

    files: dict[int, dict] = {}
    assets: dict[int, dict] = {}
    for r in rows:
        files[r["file_id"]] = dict(r)
        fields = resolved.get(r["cluster_id"], {})
        asset = assets.setdefault(r["cluster_id"], {
            "cluster_id": r["cluster_id"],
            "when": fields.get("datetime_utc"),
            "offset": fields.get("utc_offset"),
            "members": [],
        })
        asset["members"].append(
            {"file_id": r["file_id"], "mime": r["mime"], "ext": r["ext"], "role": r["role"]})
    # Canonical first, so it takes the unsuffixed name within its asset.
    for a in assets.values():
        a["members"].sort(key=lambda m: (m["role"] != "canonical", m["file_id"]))
    return list(assets.values()), files


def _resolution(db, cluster_id: int) -> tuple[dict[str, str], bool]:
    rows = db.execute(
        "SELECT field, value, source FROM resolution WHERE cluster_id = ?",
        (cluster_id,)).fetchall()
    fields = {r["field"]: r["value"] for r in rows}
    inferred = any(r["field"] == "gps" and r["source"] == "inferred" for r in rows)
    return fields, inferred


# ------------------------------------------------------------------- moving


def _preflight(out_dir: Path, stats: WriteStats, move: bool) -> None:
    """Refuse to start a run that cannot finish (PLAN §5b)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(out_dir).free
    needed = 0 if move else stats.bytes_needed
    if needed and free < needed * 1.05:
        raise SystemExit(
            f"not enough space: {needed / 1073741824:.1f} GB needed, "
            f"{free / 1073741824:.1f} GB free. Use --move, or free space first.")


def _clone(source: str, destination: Path) -> bool:
    """APFS copy-on-write clone: the copy shares the original's blocks, so it
    costs no space until one of them is modified.  Same volume only, and the
    destination must not exist.  False means "not available, copy normally"."""
    global _CLONEFILE
    if _CLONEFILE is None:
        try:
            import ctypes, ctypes.util
            lib = ctypes.CDLL(ctypes.util.find_library("System"), use_errno=True)
            fn = lib.clonefile
            fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
            fn.restype = ctypes.c_int
            _CLONEFILE = fn
        except Exception:
            _CLONEFILE = False
    if not _CLONEFILE:
        return False
    rc = _CLONEFILE(os.fsencode(source), os.fsencode(str(destination)), 0)
    if rc != 0:
        return False
    shutil.copystat(source, destination)
    return True


_CLONEFILE = None


def _place(source: str, destination: Path, move: bool, stats: WriteStats) -> bool:
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        if destination.exists() and destination.stat().st_size:
            return True                      # idempotent re-run
        if move:
            shutil.move(source, destination)
            stats.moved += 1
        else:
            if _clone(source, destination):
                stats.cloned += 1
            else:
                shutil.copy2(source, destination)
            stats.copied += 1
        return True
    except OSError as exc:
        stats.failures.append(f"{source}: {exc}")
        return False


# ---------------------------------------------------------------- embedding


def _tags(source: dict, fields: dict[str, str], gps_inferred: bool = False) -> list[str]:
    when = naming.local_time(fields.get("datetime_utc", ""), fields.get("utc_offset"))
    offset = fields.get("utc_offset")
    gps = _coords(fields.get("gps"))
    altitude = fields.get("gps_altitude")
    video = source["kind"] == "video"
    tags: list[str] = []

    if when:
        stamp = f"{when:%Y:%m:%d %H:%M:%S}"
        if video:
            # QuickTime dates are UTC by spec; Keys:CreationDate is the only one
            # that carries the shooting offset, and Photos reads it.
            utc = datetime.fromisoformat(fields["datetime_utc"])
            tags += [f"-QuickTime:CreateDate={utc:%Y:%m:%d %H:%M:%S}",
                     f"-QuickTime:ModifyDate={utc:%Y:%m:%d %H:%M:%S}",
                     f"-QuickTime:MediaCreateDate={utc:%Y:%m:%d %H:%M:%S}"]
            if offset:
                tags.append(f"-Keys:CreationDate={stamp}{offset}")
        else:
            tags += [f"-EXIF:DateTimeOriginal={stamp}", f"-EXIF:CreateDate={stamp}",
                     f"-XMP-photoshop:DateCreated={stamp}"]
            if offset:
                # D8: without this the output perpetuates the ambiguity the whole
                # timezone pass exists to remove.
                tags += [f"-EXIF:OffsetTimeOriginal={offset}",
                         f"-EXIF:OffsetTime={offset}",
                         f"-EXIF:OffsetTimeDigitized={offset}"]
        tags.append(f"-FileModifyDate={stamp}{offset or ''}")

    if gps:
        lat, lon = gps
        if video:
            coordinate = f"{lat:+.6f}{lon:+.6f}"
            tags += [f"-Keys:GPSCoordinates={lat} {lon}",
                     f"-UserData:GPSCoordinates={coordinate}/"]
        else:
            tags += [f"-EXIF:GPSLatitude={abs(lat)}",
                     f"-EXIF:GPSLatitudeRef={'N' if lat >= 0 else 'S'}",
                     f"-EXIF:GPSLongitude={abs(lon)}",
                     f"-EXIF:GPSLongitudeRef={'E' if lon >= 0 else 'W'}"]
            if altitude:
                try:
                    metres = float(altitude)
                    tags += [f"-EXIF:GPSAltitude={abs(metres)}",
                             f"-EXIF:GPSAltitudeRef={0 if metres >= 0 else 1}"]
                except ValueError:
                    pass
            if gps_inferred:
                # The standard EXIF field for how a fix was obtained. A real one
                # reads GPS or NETWORK; this says plainly that it is a guess, so
                # no map ever presents it as a measurement.
                tags.append("-EXIF:GPSProcessingMethod=ESTIMATED")

    for field_name, tag in (("make", "Make"), ("model", "Model")):
        value = fields.get(field_name)
        if value and not video:
            tags.append(f"-EXIF:{tag}={value}")
    if fields.get("description"):
        tags.append(f"-XMP-dc:Description={fields['description']}")
    if fields.get("keywords"):
        tags.append(f"-XMP-dc:Subject={fields['keywords']}")
    # The only trail back to where this file came from.
    tags.append(f"-XMP-xmpMM:PreservedFileName={Path(source['path']).name}")
    return tags


def _coords(value: str | None):
    if not value:
        return None
    try:
        lat, _, lon = value.partition(",")
        return float(lat), float(lon)
    except ValueError:
        return None


# -------------------------------------------------------------- verification


def _verify(et: ExifTool, jobs, files, targets, stats: WriteStats) -> list[int]:
    """Re-read every written file. Pixels must be untouched; tags must be there.

    Copying and rewriting a metadata block cannot change a single pixel, so this
    is an equality check rather than a tolerance — and the one place a silent
    corruption would otherwise hide.
    """
    verified: list[int] = []
    if not jobs:
        return verified
    by_path = {str(t[0]): t[0] for t in jobs}
    read = et.read(list(by_path.values()))
    wanted = {str(Path(t.relative)): t for t in targets}
    for path_text, written in by_path.items():
        target = next((t for name, t in wanted.items() if path_text.endswith(name)), None)
        source = files.get(target.file_id) if target else None
        if source is None:
            continue
        tags = read.get(path_text, {})
        if source["kind"] == "image" and source["pixel_hash"]:
            try:
                with open_oriented(written) as im:
                    if pixel_hash(im) != source["pixel_hash"]:
                        stats.failures.append(f"{written}: pixels changed on write")
                        continue
            except Exception as exc:
                stats.failures.append(f"{written}: could not re-read ({exc})")
                continue
        if source["content_id"]:
            back = (tags.get("MakerNotes:ContentIdentifier")
                    or tags.get("QuickTime:ContentIdentifier")
                    or tags.get("Keys:ContentIdentifier"))
            if back != source["content_id"]:
                # D15: Photos re-pairs Live Photos on this and nothing else.
                stats.failures.append(
                    f"{written}: ContentIdentifier lost — Live Photo will not re-pair")
                continue
        verified.append(target.file_id)
        stats.verified += 1
    return verified


def _record_verified(db, file_ids: list[int]) -> None:
    """Stamp `verified_at`, which is what `reclaim` later refuses to act without."""
    if not file_ids:
        return
    now = datetime.now(timezone.utc).isoformat()
    db.executemany("UPDATE decision SET verified_at = ? WHERE file_id = ?",
                   [(now, fid) for fid in file_ids])


def link_superseded(db) -> int:
    """Point every dropped file at the decision that replaces it.

    Without this link `reclaim` has no way to ask "is the thing that replaced
    this file proven good?", which is the whole basis on which it is allowed to
    unlink anything.
    """
    rows = db.execute("""
        SELECT d.id AS dropped, c.id AS keeper
        FROM decision d
        JOIN member m ON m.file_id = d.file_id
        JOIN member k ON k.cluster_id = m.cluster_id AND k.role = 'canonical'
        JOIN decision c ON c.file_id = k.file_id
        WHERE d.outcome IN ('duplicate', 'burst_sibling')""").fetchall()
    db.executemany("UPDATE decision SET superseded_by = ? WHERE id = ?",
                   [(r["keeper"], r["dropped"]) for r in rows])
    return len(rows)


@dataclass
class UndoStats:
    reversed: int = 0
    deleted: int = 0
    blocked: int = 0
    failures: list[str] = field(default_factory=list)
    reasons: dict[str, int] = field(default_factory=dict)

    def block(self, why: str) -> None:
        self.blocked += 1
        self.reasons[why] = self.reasons.get(why, 0) + 1


def undo_write(db, out_dir: Path, *, apply: bool = False) -> UndoStats:
    """Reverse a write, from the manifest it wrote as it went.

    A moved file is renamed back to where it came from; a copied one is simply
    removed, since its source was never touched. Neither is attempted if the
    source path is occupied — an undo that overwrites something is not an undo.

    This reverses stage 5 only. Files already staged into `.trash/` come back
    with `restore`, and anything `reclaim` unlinked is gone: that step is the
    one the whole design treats as irreversible, and it still is.
    """
    stats = UndoStats()
    manifest = out_dir / MANIFEST
    if not manifest.exists():
        stats.failures.append(f"no {MANIFEST} in {out_dir} — nothing to undo")
        return stats
    operations = json.loads(manifest.read_text(encoding="utf-8")).get("operations", [])
    for op in reversed(operations):
        source, target = Path(op["source"]), Path(op["target"])
        if not target.exists():
            stats.block("already gone from the output")
            continue
        if op["action"] == "move":
            if source.exists():
                stats.block("its original path is occupied again")
                continue
            if not apply:
                stats.reversed += 1
                continue
            try:
                source.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(target), str(source))
                stats.reversed += 1
            except OSError as exc:
                stats.failures.append(f"{target}: {exc}")
        else:
            if not source.exists():
                # Deleting the copy would leave no version of this file at all.
                stats.block("the source is missing, so this copy is the only one left")
                continue
            if not apply:
                stats.deleted += 1
                continue
            try:
                target.unlink()
                stats.deleted += 1
            except OSError as exc:
                stats.failures.append(f"{target}: {exc}")
    if apply:
        db.execute("UPDATE decision SET verified_at = NULL, target_path = NULL")
    return stats


def _manifest(out_dir: Path, operations: list[dict], stats: WriteStats) -> None:
    path = out_dir / MANIFEST
    path.write_text(json.dumps({
        "generated": datetime.now().astimezone().isoformat(),
        "assets": stats.assets, "files": stats.files,
        "copied": stats.copied, "moved": stats.moved,
        "verified": stats.verified, "failures": stats.failures,
        "operations": operations,
    }, ensure_ascii=False, indent=1), encoding="utf-8")
