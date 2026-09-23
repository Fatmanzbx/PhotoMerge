"""Stage 3, tier D — deciding whether a candidate pair is really one photo.

The BK-tree (tier C) answers "do these look alike", which is not the question.
A missed duplicate costs disk; a false merge loses a photo forever, so every
candidate has to survive this cascade before anything is collapsed, and whatever
survives C but fails D goes to the review queue rather than the bin.

Checks run cheapest-first, and the order is doing real work rather than tidiness:
the separation guards and the capture fingerprint are pure metadata, so most
pairs are decided without decoding a single pixel.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import datetime
from functools import lru_cache

import numpy as np
from PIL import Image

from photomerge.imagehash import hamming, open_oriented

# --- thresholds.  Every one of these is a judgement call; they are gathered here
# so a calibration run changes numbers in one place rather than logic in five.
ASPECT_TOLERANCE = 0.02      # relative difference that still counts as "same shape"
FINGERPRINT_SECONDS = 2      # DateTimeOriginal agreement for the capture fingerprint
PHASH_CONFIRM = 10           # of 256 bits, for a pair that already matched on dhash
SSIM_CONFIRM = 0.95          # structural confirmation when metadata cannot decide
SSIM_IDENTICAL = 0.985       # above this the frames are one photo, not two
FLAT_STDDEV = 18.0           # grayscale standard deviation below which it is "flat"
FLAT_TILE_MAE = 10.0         # per-tile mean absolute error a flat pair must beat
FLAT_GRID = 32               # tiles per side; coarser grids hide a one-digit change
ORB_INLIERS = 30             # RANSAC inliers confirming a crop or rescale (C2)
SEPARATION_HOURS = 24        # EXIF-grade times further apart than this are separate
SEPARATION_KM = 5.0          # GPS fixes further apart than this are separate
COMPARE_EDGE = 256           # long side everything is compared at

CONFIRM, BURST, REVIEW, REJECT = "confirm", "burst", "review", "reject"


@dataclass
class Facts:
    """Everything tier D knows about one file without opening it."""
    id: int
    path: str
    width: int | None = None
    height: int | None = None
    dhash64: bytes | None = None
    phash256: bytes | None = None
    make: str | None = None
    model: str | None = None
    exposure_key: str | None = None
    datetime_utc: str | None = None      # EXIF- or QuickTime-grade only
    gps: tuple[float, float] | None = None

    @property
    def aspect(self) -> float | None:
        if not self.width or not self.height:
            return None
        return self.width / self.height

    @property
    def pixels(self) -> int:
        return (self.width or 0) * (self.height or 0)


@dataclass
class Verdict:
    outcome: str
    reason: str
    checks: dict = field(default_factory=dict)

    @property
    def merges(self) -> bool:
        """A burst merges, but never on the same terms as a duplicate.

        §3.2's requirement is that collapsing a burst be *deliberate*: the frame
        kept is chosen by sharpness rather than by pixel count, the siblings are
        recorded as `burst_sibling` rather than discarded as duplicates, and
        `--keep-bursts` emits all of them from the catalog with no re-analysis.
        Those are the conditions, and stage 3 now meets them.
        """
        return self.outcome in (CONFIRM, BURST)


def verify(a: Facts, b: Facts, *, pixels: bool = True) -> Verdict:
    """Decide one candidate pair."""
    checks: dict = {}

    # 1. Separation guards run first: they are the only checks that can end the
    #    question outright, and they cost nothing (PLAN §3.1-D5).
    separated = _separation(a, b, checks)
    if separated:
        return Verdict(REJECT, separated, checks)

    # 2. Capture fingerprint — decisive when present.  Same camera, same instant,
    #    same exposure is not a coincidence two different photos can have.
    fingerprint = _fingerprint(a, b, checks)

    # 3. Shape.  A different aspect ratio means a crop, which tier C's dHash is
    #    not entitled to call a duplicate; it goes to C2 instead.
    same_shape = _same_shape(a, b, checks)

    # A pair that agrees on shape and fingerprint is as certain as metadata can
    # make it.  These already reached here as perceptual candidates, so the phash
    # distance is recorded as evidence rather than used as another gate.
    if fingerprint and same_shape:
        if not pixels:
            return Verdict(CONFIRM, "capture fingerprint and shape agree", checks)
        # Same camera and instant still leaves one ambiguity worth spending a
        # decode on: two frames of a burst look exactly like this (§3.2).
        score = _ssim(a, b, checks)
        if score is None:
            return Verdict(REVIEW, "capture fingerprint agrees but neither file could be read", checks)
        if score >= SSIM_IDENTICAL:
            return Verdict(CONFIRM, f"capture fingerprint agrees, SSIM {score:.3f}", checks)
        return Verdict(BURST, f"same camera and instant but SSIM only {score:.3f} — "
                              f"frames of one burst, not copies of one frame", checks)

    if not pixels:
        return Verdict(REVIEW, "metadata alone cannot decide", checks)

    # 4. Flat-image guard.  Sky, a white wall, two screenshots differing in one
    #    digit: all near-identical to any perceptual hash, and all different
    #    photos.  These must clear a much stricter per-tile test.
    if _is_flat(a, checks, "a") or _is_flat(b, checks, "b"):
        mae = _tile_mae(a, b, checks)
        if mae is None:
            return Verdict(REVIEW, "flat image that could not be read", checks)
        if mae > FLAT_TILE_MAE:
            return Verdict(REJECT, f"flat images differing per tile (MAE {mae:.1f})", checks)
        # The per-tile test exists precisely because these are easy to confuse.
        # Running it and then refusing to believe it was the worst of both: the
        # strict check passes, and the pair sits in a queue anyway. A tile-level
        # MAE this low means the one changed digit a screenshot would differ by
        # is not there.
        return Verdict(CONFIRM, f"flat images, but identical per tile (MAE {mae:.1f})",
                       checks)

    # 5. Structural confirmation, for everything metadata could not settle.
    score = _ssim(a, b, checks)
    if score is not None and score >= SSIM_CONFIRM and same_shape:
        return Verdict(CONFIRM, f"structurally identical (SSIM {score:.3f})", checks)

    # 6. C2 — a crop or a rescale is a real relationship that SSIM at a common
    #    size cannot see.  Ask the stronger question: is there a consistent
    #    geometric transform mapping one into the other?
    #
    #    Only for pairs that have a reason to be escalated: a differing aspect
    #    ratio, or a near miss on phash (PLAN §3.1-C2).  Run on everything it
    #    finds spurious homographies in textured images that are simply not
    #    related, and turns a clean REJECT into a review-queue entry.
    phash_distance = checks.get("phash_distance")
    if a.phash256 and b.phash256 and phash_distance is None:
        phash_distance = hamming(a.phash256, b.phash256)
        checks["phash_distance"] = phash_distance
    narrow_miss = phash_distance is not None and phash_distance <= PHASH_CONFIRM * 2
    inliers = None
    if not same_shape or narrow_miss:
        inliers = _homography_inliers(a, b, checks)
    if inliers is not None and inliers >= ORB_INLIERS:
        if same_shape:
            # Same frame, same geometry, hundreds of corresponding keypoints —
            # one photo processed twice. SSIM read low because it punishes the
            # tone and contrast differences that re-processing introduces, which
            # is exactly what it should not be trusted to judge here.
            return Verdict(CONFIRM, f"same geometry ({inliers} RANSAC inliers) at the "
                                    f"same aspect — one photo, processed twice", checks)
        # A different shape *is* a crop, and a crop is a variant (PLAN §3.3):
        # different framing is different content, so it keeps its own asset.
        return Verdict(REVIEW, f"geometrically related ({inliers} RANSAC inliers) but "
                               f"differently cropped — a variant, not a duplicate",
                       checks)

    if score is not None and score >= SSIM_CONFIRM:
        return Verdict(REVIEW, f"structurally similar (SSIM {score:.3f}) but differently "
                               f"shaped", checks)
    return Verdict(REJECT, "looks alike but nothing confirms it", checks)


# ------------------------------------------------------------------- checks


def _separation(a: Facts, b: Facts, checks: dict) -> str | None:
    if a.datetime_utc and b.datetime_utc:
        try:
            gap = abs((datetime.fromisoformat(a.datetime_utc)
                       - datetime.fromisoformat(b.datetime_utc)).total_seconds())
        except ValueError:
            gap = None
        if gap is not None:
            checks["time_gap_s"] = gap
            if gap > SEPARATION_HOURS * 3600:
                return f"capture times {gap / 3600:.1f} h apart"
    if a.gps and b.gps:
        km = haversine_km(a.gps, b.gps)
        checks["gps_km"] = km
        if km > SEPARATION_KM:
            return f"locations {km:.1f} km apart"
    return None


def _fingerprint(a: Facts, b: Facts, checks: dict) -> bool:
    if not (a.datetime_utc and b.datetime_utc):
        return False
    if not (a.model and b.model) or a.model != b.model:
        return False
    if a.make and b.make and a.make != b.make:
        return False
    if a.exposure_key and b.exposure_key and a.exposure_key != b.exposure_key:
        return False
    gap = checks.get("time_gap_s")
    if gap is None:
        try:
            gap = abs((datetime.fromisoformat(a.datetime_utc)
                       - datetime.fromisoformat(b.datetime_utc)).total_seconds())
        except ValueError:
            return False
        checks["time_gap_s"] = gap
    ok = gap <= FINGERPRINT_SECONDS
    checks["fingerprint"] = ok
    if a.phash256 and b.phash256:
        checks["phash_distance"] = hamming(a.phash256, b.phash256)
    return ok


def _same_shape(a: Facts, b: Facts, checks: dict) -> bool:
    if a.aspect is None or b.aspect is None:
        return False
    difference = abs(a.aspect - b.aspect) / max(a.aspect, b.aspect)
    checks["aspect_difference"] = difference
    return difference <= ASPECT_TOLERANCE


def _is_flat(f: Facts, checks: dict, label: str) -> bool:
    """Flatness is measured on the pixels, not on the phash.

    PLAN §3.1-D3 proposed "low phash bit entropy", which cannot work: the hash
    thresholds DCT coefficients against their own median, so **exactly half the
    bits are set for every image**, flat or busy — measured bit-mean 0.500 for a
    blank wall and for noise alike. Grayscale standard deviation does separate
    them cleanly (0.0 / 2.7 / 72.3 for a wall, a wall with one digit, and noise).
    """
    grey = _grey(f.path)
    if grey is None:
        return False
    spread = float(grey.std())
    checks[f"stddev_{label}"] = spread
    return spread < FLAT_STDDEV


def haversine_km(one: tuple[float, float], two: tuple[float, float]) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, (*one, *two))
    h = (math.sin((lat2 - lat1) / 2) ** 2
         + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2)
    return 6371.0 * 2 * math.asin(math.sqrt(h))


# ------------------------------------------------------------- pixel access


@lru_cache(maxsize=3000)
def _grey(path: str) -> np.ndarray | None:
    """A small orientation-normalised grayscale view, cached across pairs.

    Candidates arrive grouped by file, so a modest cache turns what looks like
    two decodes per pair into roughly one decode per file.
    """
    try:
        with open_oriented(path) as im:
            grey = im.convert("L")
            scale = COMPARE_EDGE / max(grey.size)
            if scale < 1:
                grey = grey.resize((max(1, int(grey.width * scale)),
                                    max(1, int(grey.height * scale))), Image.LANCZOS)
            return np.asarray(grey, dtype=np.float64)
    except Exception:
        return None


def _common(a: Facts, b: Facts) -> tuple[np.ndarray, np.ndarray] | None:
    left, right = _grey(a.path), _grey(b.path)
    if left is None or right is None:
        return None
    height = min(left.shape[0], right.shape[0])
    width = min(left.shape[1], right.shape[1])
    if height < 8 or width < 8:
        return None
    resize = lambda m: np.asarray(
        Image.fromarray(m.astype(np.uint8)).resize((width, height), Image.LANCZOS),
        dtype=np.float64)
    return resize(left), resize(right)


def _ssim(a: Facts, b: Facts, checks: dict) -> float | None:
    pair = _common(a, b)
    if pair is None:
        return None
    from skimage.metrics import structural_similarity

    score = float(structural_similarity(pair[0], pair[1], data_range=255.0))
    checks["ssim"] = score
    return score


def _tile_mae(a: Facts, b: Facts, checks: dict, grid: int = FLAT_GRID) -> float | None:
    """Worst tile's mean absolute error.

    A whole-image average hides the one corner where two otherwise blank
    screenshots differ — which is exactly where they differ. So does a coarse
    grid: measured on this library, an 8x8 grid scores a pair of screenshots
    differing in a single digit at 3.4-4.4, indistinguishable from the 0-3 that
    genuinely identical night-sky frames score. At 32x32 the digit pairs rise to
    20-33 while the real pairs stay under 5.5, which is what makes a threshold
    between them meaningful rather than arbitrary.
    """
    pair = _common(a, b)
    if pair is None:
        return None
    left, right = pair
    rows = np.array_split(np.arange(left.shape[0]), grid)
    cols = np.array_split(np.arange(left.shape[1]), grid)
    worst = 0.0
    for r in rows:
        for c in cols:
            if r.size and c.size:
                tile = np.abs(left[np.ix_(r, c)] - right[np.ix_(r, c)]).mean()
                worst = max(worst, float(tile))
    checks["tile_mae"] = worst
    return worst


def _homography_inliers(a: Facts, b: Facts, checks: dict) -> int | None:
    """ORB keypoints + RANSAC homography (PLAN §3.1-C2)."""
    import cv2

    left, right = _grey(a.path), _grey(b.path)
    if left is None or right is None:
        return None
    orb = cv2.ORB_create(nfeatures=1500)
    kp1, des1 = orb.detectAndCompute(left.astype(np.uint8), None)
    kp2, des2 = orb.detectAndCompute(right.astype(np.uint8), None)
    if des1 is None or des2 is None or len(kp1) < 8 or len(kp2) < 8:
        return None
    matcher = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
    matches = matcher.match(des1, des2)
    if len(matches) < 8:
        checks["orb_inliers"] = 0
        return 0
    src = np.float32([kp1[m.queryIdx].pt for m in matches]).reshape(-1, 1, 2)
    dst = np.float32([kp2[m.trainIdx].pt for m in matches]).reshape(-1, 1, 2)
    _, mask = cv2.findHomography(src, dst, cv2.RANSAC, 3.0)
    inliers = 0 if mask is None else int(mask.sum())
    checks["orb_inliers"] = inliers
    return inliers
