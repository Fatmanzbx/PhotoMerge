"""Content fingerprints, all computed on orientation-normalised pixels.

Orientation matters more than it looks.  The same photo can be rotated by an EXIF
tag in one copy and rotated in the pixels in another; hashing the stored buffer
(D4) means those two never cluster.  Everything here runs after
`ImageOps.exif_transpose`, so a tag-rotated and a pixel-rotated copy produce
identical hashes.
"""

from __future__ import annotations

import hashlib
from functools import lru_cache

import numpy as np
from PIL import Image, ImageOps

try:
    import pillow_heif

    pillow_heif.register_heif_opener()
    HEIF_OK = True
except ImportError:  # pragma: no cover - degrades to hash-only for HEIC
    HEIF_OK = False

Image.MAX_IMAGE_PIXELS = None

SHARPNESS_EDGE = 512  # long side the Laplacian runs on, so scores compare across sizes


def open_oriented(path) -> Image.Image:
    im = Image.open(path)
    im.load()
    return ImageOps.exif_transpose(im) or im


def sha256_file(path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def pixel_hash(im: Image.Image) -> str:
    """BLAKE2b over the decoded RGB buffer.

    Equality here means the same image in a different container or with different
    metadata — the Apple-original vs. Google-EXIF-stripped case, which is most of
    the real duplication.  Dimensions are folded in so two different images can
    never collide through a buffer-length coincidence.
    """
    rgb = im.convert("RGB")
    h = hashlib.blake2b(digest_size=16)
    h.update(f"{rgb.width}x{rgb.height}|".encode())
    h.update(rgb.tobytes())
    return h.hexdigest()


def dhash64(im: Image.Image) -> bytes:
    """8 bytes.  Cheap, and the key the BK-tree is built over (PLAN §3.1-C)."""
    a = np.asarray(_gray(im, (9, 8)), dtype=np.int16)
    return np.packbits(a[:, 1:] > a[:, :-1]).tobytes()


def phash256(im: Image.Image) -> bytes:
    """32 bytes of low-frequency DCT signature, for verifying dhash candidates."""
    a = np.asarray(_gray(im, (32, 32)), dtype=np.float64)
    coeffs = _dct(_dct(a, axis=0), axis=1)[:16, :16]
    median = np.median(np.delete(coeffs.flatten(), 0))  # drop DC, it dominates
    return np.packbits(coeffs > median).tobytes()


def sharpness(im: Image.Image) -> float:
    """Variance of the Laplacian — how the sharpest frame of a burst is chosen."""
    import cv2

    gray = im.convert("L")
    long_side = max(gray.size)
    if long_side > SHARPNESS_EDGE:
        scale = SHARPNESS_EDGE / long_side
        gray = gray.resize((max(1, int(gray.width * scale)),
                            max(1, int(gray.height * scale))), Image.LANCZOS)
    return float(cv2.Laplacian(np.asarray(gray), cv2.CV_64F).var())


def hamming(a: bytes, b: bytes) -> int:
    return int(np.unpackbits(np.frombuffer(a, np.uint8) ^ np.frombuffer(b, np.uint8)).sum())


def _gray(im: Image.Image, size: tuple[int, int]) -> Image.Image:
    return im.convert("L").resize(size, Image.LANCZOS)


@lru_cache(maxsize=4)
def _dct_matrix(n: int) -> np.ndarray:
    k = np.arange(n).reshape(-1, 1)
    x = np.arange(n).reshape(1, -1)
    return np.cos(np.pi * (2 * x + 1) * k / (2 * n))


def _dct(a: np.ndarray, axis: int) -> np.ndarray:
    m = _dct_matrix(a.shape[axis])
    return np.tensordot(m, a, axes=([1], [axis])) if axis == 0 else a @ m.T


def stream_hash(path) -> str | None:
    """MD5 of a video's encoded stream, ignoring the container and its metadata.

    The video analogue of `pixel_hash`. Two files holding the same recording
    differ in bytes whenever a tool rewrites a tag or remuxes `.mov` to `.mp4`,
    so `sha256` cannot see that they are the same video — which is why 79 such
    copies survived the first run. Copying the stream out and hashing that is
    exact, and cheap: nothing is decoded.
    """
    import subprocess

    result = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-map", "0:v:0",
         "-c", "copy", "-f", "md5", "-"],
        capture_output=True, text=True)
    out = result.stdout.strip()
    if result.returncode != 0 or not out.startswith("MD5="):
        return None
    return out[4:]
