"""Stage 2 — read every file once and record everything it says about itself.

Two passes share each batch: a process pool decodes and hashes (decode-bound,
not I/O-bound) while the single exiftool child reads tags for the same files.

Nothing here decides anything.  Competing claims — an EXIF date and a Takeout
date that disagree, a GPS fix in the sidecar and none in the pixels — are all
written to `meta` side by side for stage 4 to resolve.
"""

from __future__ import annotations

import concurrent.futures as cf
import re
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

from photomerge import imagehash
from photomerge.exiftool import ExifTool

BATCH = 120

_ZERO_DATE = "0000:00:00 00:00:00"
# A QuickTime atom that was never set reads back as the Unix epoch, and an
# "earliest wins" rule will take it seriously unless it is rejected here.
_EARLIEST_PLAUSIBLE = 1990
_DT = re.compile(
    r"^(?P<date>\d{4}[:-]\d{2}[:-]\d{2})[ T](?P<time>\d{2}:\d{2}:\d{2}(?:\.\d+)?)"
    r"(?P<off>Z|[+-]\d{2}:?\d{2})?$"
)


@dataclass
class ExtractStats:
    total: int = 0
    done: int = 0
    errors: int = 0
    claims: int = 0
    by_error: dict[str, int] = field(default_factory=dict)


def extract(
    db: sqlite3.Connection,
    *,
    workers: int = 0,
    limit: int | None = None,
    force: bool = False,
    progress=None,
) -> ExtractStats:
    import os

    workers = workers or max(1, (os.cpu_count() or 4) - 1)
    where = "status IN ('scanned','error')" if not force else "status != 'skipped'"
    sql = f"SELECT id, path, kind FROM file WHERE {where} ORDER BY id"
    if limit:
        sql += f" LIMIT {int(limit)}"
    jobs = [(r["id"], r["path"], r["kind"]) for r in db.execute(sql)]

    stats = ExtractStats(total=len(jobs))
    if not jobs:
        return stats

    with ExifTool() as et, cf.ProcessPoolExecutor(max_workers=workers) as pool:
        for start in range(0, len(jobs), BATCH):
            batch = jobs[start : start + BATCH]
            pending = pool.map(_pixel_work, batch)
            tags = et.read([Path(p) for _, p, _ in batch])
            db.execute("BEGIN")
            try:
                for (file_id, path, kind), pixels in zip(batch, pending):
                    _store(db, stats, file_id, path, kind, pixels, tags.get(path, {}))
            finally:
                db.execute("COMMIT")
            stats.done += len(batch)
            if progress:
                progress(stats)
    return stats


# --------------------------------------------------------------- pixel pass


def _pixel_work(job: tuple[int, str, str]) -> dict:
    """Runs in a worker process: hash the bytes, and for images the pixels too."""
    file_id, path, kind = job
    out: dict = {"id": file_id}
    try:
        out["sha256"] = imagehash.sha256_file(path)
    except Exception as exc:
        # A worker that raises kills the whole pool and the batch with it, so
        # every failure is returned as data instead.
        out["error"] = f"unreadable: {type(exc).__name__}: {exc}"
        return out
    if kind == "video":
        out["stream_hash"] = imagehash.stream_hash(path)
        return out
    if kind != "image":
        return out
    try:
        with imagehash.open_oriented(path) as im:
            out["width"], out["height"] = im.size
            out["pixel_hash"] = imagehash.pixel_hash(im)
            out["dhash64"] = imagehash.dhash64(im)
            out["phash256"] = imagehash.phash256(im)
            out["sharpness"] = imagehash.sharpness(im)
    except Exception as exc:
        # Degrade to hash-only and flag it; never drop the file silently.
        out["error"] = f"decode failed: {type(exc).__name__}: {exc}"
    return out


# ------------------------------------------------------------------ storage


def _store(db, stats, file_id, path, kind, pixels, tags) -> None:
    claims, columns = _interpret(tags, kind)
    error = pixels.get("error")
    if error:
        stats.errors += 1
        stats.by_error[error.split(":")[0]] = stats.by_error.get(error.split(":")[0], 0) + 1
    if not tags and not pixels.get("sha256"):
        error = error or "exiftool and hashing both failed"

    if pixels.get("width"):
        columns["width"], columns["height"] = pixels["width"], pixels["height"]

    db.execute(
        """
        UPDATE file SET sha256=?, pixel_hash=?, stream_hash=?, dhash64=?, phash256=?,
                        width=?, height=?, sharpness=?, make=?, model=?,
                        exposure_key=?, content_id=?,
                        status=?, error=?, extracted_at=?
        WHERE id=?
        """,
        (
            pixels.get("sha256"), pixels.get("pixel_hash"), pixels.get("stream_hash"),
            pixels.get("dhash64"),
            pixels.get("phash256"), columns.get("width"), columns.get("height"),
            pixels.get("sharpness"), columns.get("make"), columns.get("model"),
            columns.get("exposure_key"), columns.get("content_id"),
            "error" if error and not pixels.get("sha256") else "extracted",
            error, datetime.now(timezone.utc).isoformat(), file_id,
        ),
    )
    # Scan's path-derived claims stay; only what this stage derives is replaced.
    db.execute(
        "DELETE FROM meta WHERE file_id=? AND source IN ('exif','quicktime','xmp')",
        (file_id,),
    )
    if claims:
        db.executemany(
            "INSERT INTO meta (file_id, field, value, source, confidence) VALUES (?,?,?,?,?)",
            [(file_id, f, v, s, c) for (f, v, s), c in claims.items()],
        )
        stats.claims += len(claims)


# -------------------------------------------------------------- tag mapping


def _interpret(tags: dict, kind: str) -> tuple[dict[tuple[str, str, str], float], dict]:
    claims: dict[tuple[str, str, str], float] = {}
    columns: dict[str, object] = {}

    def claim(fieldname: str, value, source: str, confidence: float) -> None:
        if value in (None, "", []):
            return
        key = (fieldname, str(value), source)
        claims[key] = max(claims.get(key, 0.0), confidence)

    def dates(raw, source, base_confidence, *, zone_is_real: bool = True) -> None:
        local, offset = _split_dt(raw)
        if not local:
            return
        if not zone_is_real:
            # A QuickTime CreateDate is UTC by specification, so exiftool renders
            # it `+00:00` whatever zone the camera was in. Recording that as the
            # shooting offset makes every offset-less video claim UTC as its own
            # wall clock — which names it hours wrong and stops it inheriting a
            # zone from its neighbours. Only Keys:CreationDate knows the zone.
            claim("datetime_utc", _to_utc(local, offset or "+00:00"), source,
                  base_confidence)
            return
        claim("datetime_local", local, source, base_confidence)
        if offset:
            claim("utc_offset", offset, source, base_confidence)
            claim("datetime_utc", _to_utc(local, offset), source, base_confidence)

    # --- EXIF.  SubSec carries sub-second precision and the offset in one tag.
    dates(tags.get("Composite:SubSecDateTimeOriginal"), "exif", 0.95)
    dates(tags.get("EXIF:DateTimeOriginal"), "exif", 0.95)
    claim("utc_offset", tags.get("EXIF:OffsetTimeOriginal"), "exif", 0.9)
    claim("utc_offset", tags.get("EXIF:OffsetTime"), "exif", 0.7)
    if tags.get("EXIF:DateTimeOriginal") and tags.get("EXIF:OffsetTimeOriginal"):
        local, _ = _split_dt(tags["EXIF:DateTimeOriginal"])
        if local:
            claim("datetime_utc", _to_utc(local, tags["EXIF:OffsetTimeOriginal"]), "exif", 0.95)
    dates(tags.get("EXIF:CreateDate"), "exif", 0.8)
    dates(tags.get("EXIF:ModifyDate"), "exif", 0.3)

    # GPS always through Composite: EXIF:GPSLongitude is unsigned and means nothing
    # without its Ref tag, and lat and lon must move together (D3, D5).
    _gps(claim, tags.get("Composite:GPSLatitude"), tags.get("Composite:GPSLongitude"),
         tags.get("Composite:GPSAltitude"), "exif", 0.95)
    _gps(claim, tags.get("XMP:GPSLatitude"), tags.get("XMP:GPSLongitude"), None, "xmp", 0.7)

    claim("make", tags.get("EXIF:Make"), "exif", 1.0)
    claim("model", tags.get("EXIF:Model"), "exif", 1.0)
    claim("lens", tags.get("EXIF:LensModel"), "exif", 1.0)
    claim("orientation", tags.get("EXIF:Orientation"), "exif", 1.0)

    # --- QuickTime.  CreationDate (the Keys atom) is the only one that knows the
    # shooting offset; CreateDate is UTC by spec and the child runs with TZ=UTC.
    dates(tags.get("QuickTime:CreationDate"), "quicktime", 0.95)
    dates(tags.get("Keys:CreationDate"), "quicktime", 0.95)
    dates(tags.get("QuickTime:CreateDate"), "quicktime", 0.85, zone_is_real=False)
    dates(tags.get("QuickTime:MediaCreateDate"), "quicktime", 0.6, zone_is_real=False)
    for tag in ("QuickTime:GPSCoordinates", "Keys:GPSCoordinates", "UserData:GPSCoordinates"):
        parsed = _iso6709(tags.get(tag))
        if parsed:
            _gps(claim, parsed[0], parsed[1], parsed[2], "quicktime", 0.9)
            break
    claim("make", tags.get("QuickTime:Make") or tags.get("Keys:Make"), "quicktime", 1.0)
    claim("model", tags.get("QuickTime:Model") or tags.get("Keys:Model"), "quicktime", 1.0)
    claim("duration", tags.get("QuickTime:Duration"), "quicktime", 1.0)
    claim("rotation", tags.get("Composite:Rotation"), "quicktime", 1.0)

    # --- XMP
    dates(tags.get("XMP:DateCreated"), "xmp", 0.7)
    dates(tags.get("XMP:CreateDate"), "xmp", 0.6)
    claim("description", tags.get("XMP:Description"), "xmp", 1.0)
    claim("title", tags.get("XMP:Title"), "xmp", 1.0)
    claim("rating", tags.get("XMP:Rating"), "xmp", 1.0)
    subject = tags.get("XMP:Subject")
    claim("keywords", ", ".join(subject) if isinstance(subject, list) else subject, "xmp", 1.0)
    if tags.get("XMP:MotionPhoto"):
        claim("motion_photo", "1", "xmp", 1.0)

    # --- columns the clustering stages index on
    content_id = (tags.get("MakerNotes:ContentIdentifier")
                  or tags.get("QuickTime:ContentIdentifier")
                  or tags.get("Keys:ContentIdentifier"))
    if content_id:
        columns["content_id"] = str(content_id)
        claim("content_id", content_id, "exif" if kind == "image" else "quicktime", 1.0)
    columns["make"] = tags.get("EXIF:Make") or tags.get("QuickTime:Make") or tags.get("Keys:Make")
    columns["model"] = (tags.get("EXIF:Model") or tags.get("QuickTime:Model")
                        or tags.get("Keys:Model"))
    exposure = (tags.get("EXIF:ExposureTime"), tags.get("EXIF:FNumber"), tags.get("EXIF:ISO"))
    if any(v is not None for v in exposure):
        columns["exposure_key"] = "/".join("" if v is None else str(v) for v in exposure)
        claim("exposure_key", columns["exposure_key"], "exif", 1.0)
    size = tags.get("Composite:ImageSize")
    if isinstance(size, str) and " " in size:
        w, _, h = size.partition(" ")
        if w.isdigit() and h.isdigit():
            columns.setdefault("width", int(w))
            columns.setdefault("height", int(h))
    return claims, columns


def _gps(claim, lat, lon, alt, source: str, confidence: float) -> None:
    """One atomic claim.  Borrowing lat and lon separately can assemble a
    coordinate out of two different photos (D3), so they are never stored apart."""
    try:
        lat, lon = float(lat), float(lon)
    except (TypeError, ValueError):
        return
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return
    if (lat, lon) == (0.0, 0.0):
        return  # the "no location" sentinel; a real equator fix keeps its sign elsewhere
    claim("gps", f"{lat:.7f},{lon:.7f}", source, confidence)
    if alt is not None:
        try:
            claim("gps_altitude", f"{float(alt):.3f}", source, confidence)
        except (TypeError, ValueError):
            pass


def _iso6709(raw) -> tuple[float, float, float | None] | None:
    """`-n` renders GPSCoordinates as 'lat lon [alt]'; without it, ISO 6709."""
    if not raw:
        return None
    text = str(raw).strip()
    parts = text.replace(",", " ").split()
    if len(parts) >= 2:
        try:
            return float(parts[0]), float(parts[1]), float(parts[2]) if len(parts) > 2 else None
        except ValueError:
            pass
    m = re.match(r"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)(?:([+-]\d+(?:\.\d+)?))?", text)
    if m:
        return (float(m.group(1)), float(m.group(2)),
                float(m.group(3)) if m.group(3) else None)
    return None


def _split_dt(raw) -> tuple[str | None, str | None]:
    """exiftool's `YYYY:MM:DD HH:MM:SS[.sss][±HH:MM]` -> (ISO local, offset)."""
    if not raw:
        return None, None
    text = str(raw).strip()
    if text.startswith(_ZERO_DATE[:10]):
        return None, None
    m = _DT.match(text)
    if not m:
        return None, None
    time_part = m.group("time")
    whole, _, fraction = time_part.partition(".")
    if fraction and not fraction.strip("0"):
        # `11:48:17.000` and `11:48:17` are the same instant.  Left alone they
        # reach stage 4 as two competing claims that in fact agree.  A non-zero
        # fraction is kept verbatim — it is real sub-second precision.
        time_part = whole
    local = f"{m.group('date').replace(':', '-')}T{time_part}"
    offset = m.group("off")
    if offset == "Z":
        offset = "+00:00"
    elif offset and ":" not in offset:
        offset = f"{offset[:3]}:{offset[3:]}"
    try:
        parsed = datetime.fromisoformat(local)
    except ValueError:
        return None, None
    if parsed.year < _EARLIEST_PLAUSIBLE:
        return None, None
    return local, offset


def _to_utc(local: str, offset: str) -> str:
    sign = -1 if offset[0] == "-" else 1
    hours, _, minutes = offset[1:].partition(":")
    delta = timedelta(hours=int(hours), minutes=int(minutes or 0)) * sign
    return (datetime.fromisoformat(local) - delta).replace(tzinfo=timezone.utc).isoformat()
