"""Where each kept file lands and what it is called.

One tree, `RESULT/YYYY/MM/`, named from the **resolved local** wall clock, so the
library sorts chronologically in any file browser and a single `osxphotos import`
brings it in (PLAN §5, decided 2026-09-17).

The extension comes from the file's *detected* type, never from its old name.
That is what unifies `.jpeg`/`.JPG`/`.jpg` into one spelling and renames `.MP` and
`.mp_original` to the containers they already are — a correction, not a
conversion. No pixels are touched anywhere in this module.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Detected type -> the one spelling used in the output.
EXTENSION = {
    "image/jpeg": ".jpg", "image/heic": ".heic", "image/heif": ".heic",
    "image/png": ".png", "image/gif": ".gif", "image/webp": ".webp",
    "image/tiff": ".tif", "image/avif": ".avif",
    "image/x-adobe-dng": ".dng", "image/x-canon-cr2": ".cr2",
    "image/bmp": ".bmp",
    "video/quicktime": ".mov", "video/mp4": ".mp4", "video/3gpp": ".3gp",
    "video/x-msvideo": ".avi", "video/x-matroska": ".mkv",
}

_OFFSET = re.compile(r"^([+-])(\d{2}):?(\d{2})$")


@dataclass
class Target:
    file_id: int
    cluster_id: int
    relative: str          # e.g. 2024/11/20241127_114817.heic
    stem: str
    role: str

    @property
    def path(self) -> Path:
        return Path(self.relative)


def local_time(utc_iso: str, offset: str | None) -> datetime | None:
    """The wall clock the photo was taken at, which is what a name should read."""
    try:
        when = datetime.fromisoformat(utc_iso)
    except (TypeError, ValueError):
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    shift = parse_offset(offset)
    return (when + shift).replace(tzinfo=None) if shift is not None else when.replace(tzinfo=None)


def parse_offset(offset: str | None) -> timedelta | None:
    if not offset:
        return None
    m = _OFFSET.match(offset.strip())
    if not m:
        return None
    sign = 1 if m.group(1) == "+" else -1
    return sign * timedelta(hours=int(m.group(2)), minutes=int(m.group(3)))


def extension_for(mime: str | None, fallback: str | None) -> str:
    if mime and mime in EXTENSION:
        return EXTENSION[mime]
    return (fallback or "").lower() or ".bin"


def plan_targets(assets: list[dict]) -> list[Target]:
    """Assign every kept file its output path.

    `assets` is one dict per cluster: `{cluster_id, when, offset, members}` where
    each member carries `file_id`, `mime`, `ext` and `role`.

    A Live Photo's two halves share a stem and differ only in extension, because
    that is what makes the pair legible on disk — Photos itself re-pairs on
    `ContentIdentifier`, not on the name (D15), so this is for the human.
    """
    stems: dict[str, int] = {}
    targets: list[Target] = []
    for asset in sorted(assets, key=lambda a: (a["when"] or "", a["cluster_id"])):
        when = local_time(asset["when"], asset["offset"]) if asset["when"] else None
        folder = f"{when:%Y/%m}" if when else "undated"
        base = f"{when:%Y%m%d_%H%M%S}" if when else f"asset_{asset['cluster_id']:06d}"

        # One suffix per *asset*, so the pair keeps a single shared stem.
        seen = stems.get(base, 0)
        stems[base] = seen + 1
        stem = base if seen == 0 else f"{base}_{seen}"

        used: set[str] = set()
        for member in asset["members"]:
            ext = extension_for(member.get("mime"), member.get("ext"))
            # An edit sits beside its origin and says so, rather than taking a
            # bare `_1` that reads like a filename collision.
            suffix = "_edited" if member.get("role") == "variant" else ""
            name = f"{stem}{suffix}{ext}"
            # Two files of the same type in one asset (a Live Photo whose movie
            # is the same container as another) still need distinct names.
            bump = 1
            while name in used:
                name = f"{stem}{suffix}_{bump}{ext}"
                bump += 1
            used.add(name)
            targets.append(Target(member["file_id"], asset["cluster_id"],
                                  f"{folder}/{name}", stem, member["role"]))
    return targets
