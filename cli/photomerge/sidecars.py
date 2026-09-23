"""Finding sidecars and reading what they claim.

Takeout hides capture time and GPS in `*.supplemental-metadata.json`, not in the
image (PLAN §2).  Matching them is the cascade below, measured at 98.0% on the
real export with the remaining 2% being companions and variants that legitimately
have none and inherit from their still or their origin.

Two `(n)` collision conventions exist in the same export and both are handled:

    IMG_0088 (1).jpeg   ->  IMG_0088 (1).jpeg.supplemental-metadata.json
    IMG_0899(1).HEIC    ->  IMG_0899.HEIC.supplemental-metadata(1).json

Extension case need not agree either — `IMG_0460(1).mov`'s sidecar is written
against `.mov` while the media file on disk is `IMG_0460.MOV` — so every lookup
goes through a case-folded index of the directory.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path

SUPPLEMENTAL = ".supplemental-metadata"

# Google's edit-naming, longest first.  `~2` is deliberately *not* here: it marks
# a second copy of the capture and belongs to the origin's own filename, so
# `NAME~2-edited.jpg` inherits from `NAME~2.jpg`, not from `NAME.jpg`.
EDIT_SUFFIXES = ("-EFFECTS-edited", "-edited", "-EFFECTS")
ORIGINAL_PREFIX = re.compile(r"^original_[0-9a-f-]{36}_", re.I)
COPY_SUFFIX = re.compile(r"~\d+$")

_PAREN_N = re.compile(r"^(?P<base>.*)\((?P<n>\d+)\)$")

# Google writes (0, 0) to mean "no location".  A real coordinate on the equator
# or the prime meridian must still survive (D5), so only the exact origin pair is
# treated as absent — not `lat == 0` or `lon == 0` on their own.
_NULL_ISLAND = (0.0, 0.0)


class DirIndex:
    """Case-folded listing of a directory, built once and reused.

    Sidecar lookup is thousands of near-misses per directory; stat-ing each
    candidate would dominate the scan.  One listdir per directory does not.
    """

    def __init__(self) -> None:
        self._cache: dict[Path, dict[str, str]] = {}

    def names(self, directory: Path) -> dict[str, str]:
        idx = self._cache.get(directory)
        if idx is None:
            try:
                idx = {e.name.casefold(): e.name for e in directory.iterdir()}
            except OSError:
                idx = {}
            self._cache[directory] = idx
        return idx

    def get(self, directory: Path, name: str) -> Path | None:
        actual = self.names(directory).get(name.casefold())
        return directory / actual if actual else None

    def glob_one(self, directory: Path, prefix: str, suffix: str) -> Path | None:
        pre, suf = prefix.casefold(), suffix.casefold()
        for low, actual in sorted(self.names(directory).items()):
            if low.startswith(pre) and low.endswith(suf):
                return directory / actual
        return None


def find_sidecars(path: Path, index: DirIndex) -> list[tuple[str, Path, str]]:
    """Return `[(kind, sidecar_path, rule), ...]` for one media file.

    `rule` records which branch of the cascade matched, so the survey can report
    the mix and a surprising distribution is visible rather than silent.
    """
    found: list[tuple[str, Path, str]] = []
    google = _find_google_json(path, index)
    if google:
        found.append(("google_json", *google))
    for kind, suffix in (("aae", ".aae"), ("xmp", ".xmp")):
        for stem in (path.name, path.stem):
            hit = index.get(path.parent, stem + suffix)
            if hit:
                found.append((kind, hit, "stem"))
                break
    return found


def _find_google_json(path: Path, index: DirIndex) -> tuple[Path, str] | None:
    d, name = path.parent, path.name

    # 1. The overwhelmingly common shape, and the bare `.json` fallback.
    for candidate, rule in ((name + SUPPLEMENTAL + ".json", "exact"),
                            (name + ".json", "bare")):
        hit = index.get(d, candidate)
        if hit:
            return hit, rule

    # 2. A supplemental suffix Google truncated to fit a filename limit.
    #    Absent from this export (PLAN §0) but cheap to keep for other people's.
    hit = index.glob_one(d, name + ".supplemental", ".json")
    if hit:
        return hit, "truncated"

    # 3. Collision suffix carried on the sidecar stem instead of the media name:
    #    IMG_0899(1).HEIC -> IMG_0899.HEIC.supplemental-metadata(1).json
    m = _PAREN_N.match(path.stem)
    if m:
        base, n = m.group("base").rstrip(), m.group("n")
        for candidate in (f"{base}{path.suffix}{SUPPLEMENTAL}({n}).json",
                          f"{base}{path.suffix}({n}).json"):
            hit = index.get(d, candidate)
            if hit:
                return hit, "suffix_n"

    # 4. Extensionless media, or a sidecar written against a different extension.
    hit = index.glob_one(d, path.stem + ".", ".json")
    if hit:
        return hit, "stem"

    # 5. Motion Photo still: X.MP.jpg carries another extension inside its stem.
    if path.stem.lower().endswith(".mp") or path.suffix.lower() in (".mp", ".mp_original"):
        base = path.name[: path.name.lower().rindex(".mp")]
        hit = index.glob_one(d, base + ".", ".json")
        if hit:
            return hit, "motion_photo"

    # 6. An edit inherits from its origin — Google ships no sidecar for these.
    origin = edit_origin(name)
    if origin:
        hit = index.glob_one(d, origin + ".", ".json") or index.get(d, origin + ".json")
        if hit:
            return hit, "edited_origin"

    return None


def edit_origin(name: str) -> str | None:
    """`PXL_1234-edited.jpg` -> `PXL_1234`.  None when the name is not an edit."""
    stem = Path(name).stem
    for suffix in EDIT_SUFFIXES:
        if stem.lower().endswith(suffix.lower()):
            return stem[: -len(suffix)]
    return None


def strip_google_decoration(name: str) -> str:
    """Reduce a Takeout filename to the capture stem it and its siblings share.

    `original_<uuid>_IMG_0752~2-edited.jpg` and `IMG_0752.HEIC` are the same
    photo; this is what makes them comparable before any hashing happens.  It is
    a grouping hint only — filename equality never justifies a merge (PLAN §0).
    """
    stem = Path(name).stem
    stem = ORIGINAL_PREFIX.sub("", stem)
    for suffix in EDIT_SUFFIXES:
        if stem.lower().endswith(suffix.lower()):
            stem = stem[: -len(suffix)]
            break
    m = _PAREN_N.match(stem)
    if m:
        stem = m.group("base").rstrip()
    stem = COPY_SUFFIX.sub("", stem)
    if stem.lower().endswith(".mp"):
        stem = stem[:-3]
    return stem


def parse_google_json(payload: dict) -> list[tuple[str, str, float]]:
    """Turn one Takeout sidecar into `[(field, value, confidence), ...]`.

    Timestamps are UTC instants and are stored as such.  The v0 script converted
    them to the *machine's* timezone and then dropped the tzinfo (D2), which made
    the output depend on where the merge was run.
    """
    claims: list[tuple[str, str, float]] = []

    taken = _timestamp(payload.get("photoTakenTime"))
    if taken:
        claims.append(("datetime_utc", taken, 0.9))
    created = _timestamp(payload.get("creationTime"))
    if created:
        # Upload time, not capture time.  Kept as evidence of last resort only.
        claims.append(("upload_datetime_utc", created, 0.2))

    # geoDataExif is the camera's own fix; geoData may have been typed into the
    # Google UI by hand, and §4.2 ranks a camera above a dropped pin. They are
    # byte-identical in all 2,280 sidecars here that carry both, so the order
    # changes nothing on this library — it is for the ones where it would.
    for key, confidence in (("geoDataExif", 0.9), ("geoData", 0.85)):
        gps = _coords(payload.get(key))
        if gps:
            lat, lon, alt = gps
            claims.append(("gps", f"{lat},{lon}", confidence))
            if alt is not None:
                claims.append(("gps_altitude", str(alt), confidence))
            break

    title = (payload.get("title") or "").strip()
    if title:
        claims.append(("original_filename", title, 1.0))
    description = (payload.get("description") or "").strip()
    if description:
        claims.append(("description", description, 1.0))
    if payload.get("favorited"):
        claims.append(("favorite", "1", 1.0))
    people = [p.get("name") for p in payload.get("people") or [] if p.get("name")]
    if people:
        claims.append(("people", ", ".join(people), 1.0))
    return claims


def _timestamp(block: object) -> str | None:
    if not isinstance(block, dict):
        return None
    raw = block.get("timestamp")
    try:
        epoch = int(raw)
    except (TypeError, ValueError):
        return None
    if epoch <= 0:
        return None
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat()


def _coords(block: object) -> tuple[float, float, float | None] | None:
    if not isinstance(block, dict):
        return None
    lat, lon = block.get("latitude"), block.get("longitude")
    if not isinstance(lat, (int, float)) or not isinstance(lon, (int, float)):
        return None
    if (float(lat), float(lon)) == _NULL_ISLAND:
        return None
    alt = block.get("altitude")
    return float(lat), float(lon), float(alt) if isinstance(alt, (int, float)) else None


def load(path: Path) -> dict | None:
    try:
        with open(path, "rb") as f:
            payload = json.load(f)
    except (OSError, ValueError):
        return None
    return payload if isinstance(payload, dict) else None
