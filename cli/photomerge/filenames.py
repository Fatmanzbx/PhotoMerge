"""Dates hiding in filenames, and what the folder name is worth.

Weak evidence, but it beats file mtime, which is what the v0 script silently fell
back to before letting it choose the output folder (D11).  Whether a pattern
encodes a *wall clock* or a *UTC instant* is recorded, because §4.1 cannot
reconcile timezones for claims that do not say which they are.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone

# Cameras and messaging apps that stamp a local wall clock into the name.
_WALL_PATTERNS = (
    # PXL_20250720_161254963, IMG_20240101_120000, VID_20241212_105113
    re.compile(r"(?:^|[^0-9])(?P<d>20\d{6})[_-](?P<t>\d{6})(?P<ms>\d{3})?(?:[^0-9]|$)"),
    # Screenshot_20190101-120000, 2024-01-01-120000
    re.compile(r"(?:^|[^0-9])(?P<d>20\d{2}-\d{2}-\d{2})[ _-](?P<t>\d{2}[.:-]\d{2}[.:-]\d{2})"),
    # "Screenshot 2024-01-01 at 12.00.00", "2024-01-01 12.00.00"
    re.compile(r"(?P<d>20\d{2}-\d{2}-\d{2})\s+(?:at\s+)?(?P<t>\d{2}\.\d{2}\.\d{2})"),
    # IMG-20240101-WA0001 (WhatsApp): date only
    re.compile(r"(?:^|[^0-9])(?P<d>20\d{6})-WA\d+", re.I),
)

# Apps that stamp a Unix epoch: an instant, unambiguous, always UTC.
_EPOCH_PATTERN = re.compile(
    r"(?:^|[^0-9])(?:mmexport|Video|VideoCapture|wx_camera_|IMG_|微信图片_)?(?P<e>1[0-9]{9}|1[0-9]{12})(?:[^0-9]|$)"
)

_FOLDER_YEAR = re.compile(r"^Photos from (?P<y>(?:19|20)\d{2})$", re.I)

_MIN_YEAR, _MAX_YEAR = 1995, datetime.now().year + 1


def datetime_from_name(name: str) -> tuple[str, str] | None:
    """Return `(field, iso_value)` where field is `datetime_local`/`datetime_utc`."""
    for pattern in _WALL_PATTERNS:
        m = pattern.search(name)
        if not m:
            continue
        date = m.groupdict().get("d", "")
        time = m.groupdict().get("t") or "000000"
        digits = re.sub(r"\D", "", date) + re.sub(r"\D", "", time)
        parsed = _wall(digits)
        if parsed:
            return "datetime_local", parsed
    m = _EPOCH_PATTERN.search(name)
    if m:
        raw = m.group("e")
        epoch = int(raw) / 1000 if len(raw) > 10 else int(raw)
        try:
            dt = datetime.fromtimestamp(epoch, timezone.utc)
        except (OverflowError, OSError, ValueError):
            return None
        if _MIN_YEAR <= dt.year <= _MAX_YEAR:
            return "datetime_utc", dt.isoformat()
    return None


def _wall(digits: str) -> str | None:
    if len(digits) < 8:
        return None
    digits = (digits + "000000")[:14]
    try:
        dt = datetime.strptime(digits, "%Y%m%d%H%M%S")
    except ValueError:
        return None
    if not _MIN_YEAR <= dt.year <= _MAX_YEAR:
        return None
    return dt.isoformat()


def folder_claims(parts: tuple[str, ...]) -> list[tuple[str, str, float]]:
    """What the folders above a file say about it.

    Takeout puts every photo under `Photos from <year>` and additionally copies
    album members into a folder named after the album — the album name is the
    only place that membership survives the export, and `osxphotos import`
    can put it back (README §5b).
    """
    claims: list[tuple[str, str, float]] = []
    for part in parts:
        m = _FOLDER_YEAR.match(part)
        if m:
            claims.append(("year", m.group("y"), 0.3))
        elif part not in ("Google Photos", "Takeout"):
            claims.append(("album", part, 0.8))
    return claims
