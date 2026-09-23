"""Tier C and D for video — the part the first run did not have.

Videos got `sha256` and nothing else, so anything Google re-encoded or a tool
re-muxed survived as a separate asset: 199 redundant copies, 3.57 GB, in a
library that was otherwise deduplicated. This is the video analogue of what
§3.1-C and D already do for photographs.

    tier B  equal `stream_hash`        — same encoded stream, different
                                         container or metadata. Certain.
    tier C  same duration and capture  — candidates only.
    tier D  sampled frames agree       — confirmation.

Frames are sampled rather than decoded whole: three positions is enough to tell
one recording from another, and decoding a 36-second clip to compare it with
another is not.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass, field
from io import BytesIO

from PIL import Image

from photomerge.imagehash import dhash64, hamming

DURATION_TOLERANCE = 0.15    # seconds; containers round differently
CAPTURE_TOLERANCE = 3.0      # seconds between capture times
FRAME_POSITIONS = (0.1, 0.5, 0.9)   # fractions of the duration
FRAME_DISTANCE = 8           # per-frame dHash distance allowed
SAMPLE_EDGE = 160


@dataclass
class VideoFacts:
    id: int
    path: str
    duration: float | None = None
    instant: float | None = None      # capture time, epoch seconds
    width: int | None = None
    height: int | None = None
    size: int = 0
    stream_hash: str | None = None

    @property
    def pixels(self) -> int:
        return (self.width or 0) * (self.height or 0)


@dataclass
class VideoVerdict:
    outcome: str        # confirm | reject | review
    reason: str
    checks: dict = field(default_factory=dict)

    @property
    def merges(self) -> bool:
        return self.outcome == "confirm"


def candidates(videos: list[VideoFacts]) -> set[tuple[int, int]]:
    """Pairs worth checking: the same length, taken at the same moment.

    Duration alone is uselessly broad — hundreds of Live Photo clips are 1.1 s
    and share nothing else. Capture time is what makes it a candidate.
    """
    pairs: set[tuple[int, int]] = set()
    ordered = sorted((v for v in videos if v.duration and v.instant),
                     key=lambda v: v.instant)
    for i, a in enumerate(ordered):
        for b in ordered[i + 1:]:
            if b.instant - a.instant > CAPTURE_TOLERANCE:
                break
            if abs((a.duration or 0) - (b.duration or 0)) <= DURATION_TOLERANCE:
                pairs.add((a.id, b.id) if a.id < b.id else (b.id, a.id))
    return pairs


def verify(a: VideoFacts, b: VideoFacts) -> VideoVerdict:
    checks: dict = {}
    if a.stream_hash and a.stream_hash == b.stream_hash:
        return VideoVerdict("confirm", "identical video stream", checks)

    checks["duration_gap"] = abs((a.duration or 0) - (b.duration or 0))
    checks["capture_gap"] = abs((a.instant or 0) - (b.instant or 0))

    left, right = _frames(a), _frames(b)
    if not left or not right or len(left) != len(right):
        return VideoVerdict("review", "could not sample frames from both", checks)

    distances = [hamming(x, y) for x, y in zip(left, right)]
    checks["frame_distances"] = distances
    worst = max(distances)
    if worst <= FRAME_DISTANCE:
        return VideoVerdict(
            "confirm",
            f"same recording re-encoded — sampled frames agree (worst {worst})",
            checks)
    return VideoVerdict(
        "reject", f"frames differ (worst {worst}) — different recordings", checks)


def choose(videos: list[VideoFacts]) -> VideoFacts:
    """Most pixels, then largest. A re-encode is usually smaller *and* softer,
    and the 1280x720-against-1920x1080 pairs in the real library show the copies
    are not interchangeable."""
    return max(videos, key=lambda v: (v.pixels, v.size, v.path))


def _frames(v: VideoFacts) -> list[bytes] | None:
    if not v.duration:
        return None
    out: list[bytes] = []
    for fraction in FRAME_POSITIONS:
        when = max(0.0, min(v.duration - 0.05, v.duration * fraction))
        result = subprocess.run(
            ["ffmpeg", "-v", "error", "-ss", f"{when:.3f}", "-i", v.path,
             "-frames:v", "1", "-vf", f"scale={SAMPLE_EDGE}:-1",
             "-f", "image2pipe", "-vcodec", "png", "-"],
            capture_output=True)
        if result.returncode != 0 or not result.stdout:
            return None
        try:
            with Image.open(BytesIO(result.stdout)) as frame:
                out.append(dhash64(frame))
        except Exception:
            return None
    return out
