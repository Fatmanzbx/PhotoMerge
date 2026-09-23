"""Stage 5c — make the written pairs into Live Photos Apple Photos will recognise.

Two things happen here, and both were different from what PLAN §5d assumed.

**The remux needs an explicit stream map.** A Google Motion Photo holds four
streams: the motion video, a second single-frame "video" that is really the
still at higher resolution, and two data tracks. `ffmpeg -i X.MP -c copy` — the
recipe as written — selects by highest resolution and therefore keeps the
*still*, turning a 3.7 MB motion clip into a 198 KB single frame. `-map 0:v:0`
takes the motion. Still a stream copy: nothing is re-encoded.

**The pairing is delegated.** Photos associates a pair by a `ContentIdentifier`
written into the Apple MakerNotes of the still and the `Keys` atom of the movie.
**exiftool cannot write it** — it will not create an Apple MakerNotes block that
is not already there, and fails silently on all five plausible tags. `makelive`
(an osxphotos dependency, already installed) does it correctly, so this module
calls that rather than reinventing Apple's format. It also gives a real
verification: `is_live_photo_pair` returns the shared identifier or nothing.
"""

from __future__ import annotations

import shutil
import sqlite3
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

# Containers whose video stream must be lifted out before Photos will take it.
MOTION_SOURCES = (".mp", ".mp_original")


@dataclass
class LiveStats:
    pairs: int = 0
    already_paired: int = 0
    remuxed: int = 0
    paired: int = 0
    skipped: int = 0
    failures: list[str] = field(default_factory=list)
    notes: dict[str, int] = field(default_factory=dict)

    def note(self, key: str) -> None:
        self.notes[key] = self.notes.get(key, 0) + 1


def pair_live_photos(
    db: sqlite3.Connection,
    out_dir: Path,
    *,
    apply: bool = False,
    limit: int | None = None,
) -> LiveStats:
    stats = LiveStats()
    try:
        import makelive
    except ImportError:
        stats.failures.append(
            "makelive is not installed — `pip install makelive` (it ships with osxphotos)")
        return stats

    rows = db.execute("""
        SELECT still.target_path  AS still_path,
               movie.target_path  AS movie_path,
               mf.ext             AS movie_ext,
               sf.rel_path        AS still_source
        FROM member m
        JOIN file mf ON mf.id = m.file_id
        JOIN decision movie ON movie.file_id = mf.id
        JOIN member k ON k.cluster_id = m.cluster_id AND k.role = 'canonical'
        JOIN file sf ON sf.id = k.file_id
        JOIN decision still ON still.file_id = sf.id
        WHERE m.role = 'companion' AND sf.kind = 'image'
          AND still.target_path IS NOT NULL AND movie.target_path IS NOT NULL
        ORDER BY still.target_path""").fetchall()

    for row in rows[: limit or None]:
        still = out_dir / row["still_path"]
        movie = out_dir / row["movie_path"]
        stats.pairs += 1
        if not still.exists() or not movie.exists():
            stats.skipped += 1
            stats.note("not written yet — run `write --apply` first")
            continue

        if makelive.is_live_photo_pair(still, movie):
            stats.already_paired += 1
            stats.note("already a Live Photo (came from Apple with its identifier)")
            continue
        if not apply:
            stats.note("would pair")
            continue

        target = movie
        if row["movie_ext"] in MOTION_SOURCES:
            target = movie.with_suffix(".mov")
            if not _extract_motion(movie, target, stats):
                continue
            if target != movie:
                movie.unlink(missing_ok=True)
            stats.remuxed += 1
        try:
            makelive.make_live_photo(still, target)
        except Exception as exc:
            stats.failures.append(f"{still.name}: {type(exc).__name__}: {exc}")
            continue
        if not makelive.is_live_photo_pair(still, target):
            # The failure §5d warned about is silent, so it is checked for.
            stats.failures.append(
                f"{still.name}: identifiers written but the pair does not read back")
            continue
        stats.paired += 1
    return stats


def _extract_motion(source: Path, target: Path, stats: LiveStats) -> bool:
    """Lift the motion video out of a Motion Photo container, stream-copied."""
    if shutil.which("ffmpeg") is None:
        stats.failures.append("ffmpeg not found — `brew install ffmpeg`")
        return False
    temporary = target.with_name(target.name + ".part")
    result = subprocess.run(
        # `-f mov` is explicit because the temporary name ends in `.part`, from
        # which ffmpeg cannot infer a container.
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(source),
         "-map", "0:v:0", "-c", "copy", "-f", "mov", str(temporary)],
        capture_output=True, text=True)
    if result.returncode != 0 or not temporary.exists():
        temporary.unlink(missing_ok=True)
        stats.failures.append(f"{source.name}: ffmpeg failed — {result.stderr.strip()[:90]}")
        return False
    # A remux that lost the motion is worse than none: it silently replaces a
    # clip with one frame of it.
    if temporary.stat().st_size < source.stat().st_size * 0.5:
        stats.failures.append(
            f"{source.name}: remux kept only {temporary.stat().st_size:,} of "
            f"{source.stat().st_size:,} bytes — refusing to replace the clip")
        temporary.unlink(missing_ok=True)
        return False
    temporary.replace(target)
    return True
