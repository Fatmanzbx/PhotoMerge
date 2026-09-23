"""Deterministically built fixtures — no real photos required (PLAN §8).

Anyone can contribute a failing test without shipping their library, which is
the whole point.  Tags are written with exiftool rather than a Python EXIF
writer so the fixtures exercise the same reader the pipeline uses.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image

SEED = 20260917


def noise_image(width: int = 240, height: int = 180, seed: int = SEED) -> Image.Image:
    """A textured image — flat colour would make dHash and sharpness meaningless."""
    rng = np.random.default_rng(seed)
    base = rng.integers(0, 255, size=(height, width, 3), dtype=np.uint8)
    # A few hard edges, so variance-of-Laplacian has something to measure.
    base[height // 3 : height // 2, :, :] = 250
    base[:, width // 4 : width // 3, :] = 10
    return Image.fromarray(base, "RGB")


def write_jpeg(path: Path, image: Image.Image | None = None, quality: int = 95) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    (image or noise_image()).save(path, "JPEG", quality=quality)
    return path


def exiftool_set(path: Path, *tags: str) -> None:
    subprocess.run(
        ["exiftool", "-overwrite_original", "-q", "-m", *tags, str(path)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def write_takeout_sidecar(
    media: Path,
    *,
    taken_epoch: int,
    lat: float | None = None,
    lon: float | None = None,
    alt: float | None = None,
    name: str | None = None,
) -> Path:
    geo = {"latitude": lat or 0.0, "longitude": lon or 0.0, "altitude": alt or 0.0,
           "latitudeSpan": 0.0, "longitudeSpan": 0.0}
    payload = {
        "title": media.name,
        "description": "",
        "photoTakenTime": {"timestamp": str(taken_epoch), "formatted": ""},
        "creationTime": {"timestamp": str(taken_epoch + 3600), "formatted": ""},
        "geoData": geo,
        "geoDataExif": geo,
    }
    sidecar = media.parent / (name or f"{media.name}.supplemental-metadata.json")
    sidecar.write_text(json.dumps(payload), encoding="utf-8")
    return sidecar


def write_mov(path: Path) -> Path:
    """A minimal QuickTime file: enough header for the sniffer, no codec needed."""
    path.parent.mkdir(parents=True, exist_ok=True)
    ftyp = b"\x00\x00\x00\x14ftypqt  \x00\x00\x02\x00qt  "
    path.write_bytes(ftyp + b"\x00\x00\x00\x08free" + b"\x00" * 64)
    return path


def write_mp4(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    ftyp = b"\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom"
    path.write_bytes(ftyp + b"\x00\x00\x00\x08free" + b"\x00" * 64)
    return path


def photo_image(width: int = 480, height: int = 360, seed: int = SEED) -> Image.Image:
    """Something that behaves like a photograph under JPEG and under dHash.

    Pure noise is the worst case for both: it does not survive quantisation and
    its perceptual hash moves wildly for a one-pixel shift, so tests built on it
    measure the fixture rather than the code. A photograph is mostly smooth with
    a few strong edges, which is what this builds.
    """
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:height, 0:width].astype(np.float64)
    sky = 90 + 110 * (1 - y / height)
    sun = 120 * np.exp(-(((x - width * 0.7) ** 2 + (y - height * 0.25) ** 2)
                         / (2 * (width * 0.12) ** 2)))
    ground = np.where(y > height * 0.65, -55.0, 0.0)
    base = sky + sun + ground
    for _ in range(6):                       # a few hard edges to key on
        cx, cy = rng.integers(0, width), rng.integers(0, height)
        w, h = rng.integers(20, 70), rng.integers(20, 70)
        base[max(0, cy - h):cy + h, max(0, cx - w):cx + w] += rng.integers(-60, 60)
    base += rng.normal(0, 3, base.shape)     # sensor grain, not white noise
    channels = [np.clip(base * k, 0, 255).astype(np.uint8) for k in (1.0, 0.96, 0.9)]
    return Image.fromarray(np.dstack(channels), "RGB")


def flat_image(width: int = 240, height: int = 180, shade: int = 235,
               label: str | None = None) -> Image.Image:
    """A near-blank image, optionally with one small mark.

    Sky, a white wall, and two screenshots differing in a single digit all look
    like this, and all defeat a perceptual hash — PLAN §3.1-D3.
    """
    from PIL import ImageDraw

    im = Image.new("RGB", (width, height), (shade, shade, shade))
    if label:
        ImageDraw.Draw(im).text((width // 2, height // 2), label, fill=(20, 20, 20))
    return im


def shifted_image(base: Image.Image, dx: int = 4, dy: int = 3) -> Image.Image:
    """The same scene a moment later — what a burst's next frame looks like."""
    import numpy as np

    a = np.asarray(base)
    return Image.fromarray(np.roll(np.roll(a, dy, axis=0), dx, axis=1), "RGB")


def write_motion_photo(path: Path, *, frames: int = 40) -> Path:
    """A Google Motion Photo's container shape: the motion clip *plus* a
    single-frame stream that is really the still at higher resolution.

    The second stream is the whole difficulty — it is larger, so ffmpeg's
    default stream selection prefers it and a plain `-c copy` silently keeps one
    frame instead of the clip.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error",
         "-f", "lavfi", "-i", f"testsrc=duration={frames / 20}:size=320x240:rate=20",
         "-f", "lavfi", "-i", "testsrc=duration=0.05:size=640x480:rate=20",
         "-map", "0:v", "-map", "1:v", "-c:v", "libx264", "-pix_fmt", "yuv420p",
         "-f", "mp4", str(path)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return path
