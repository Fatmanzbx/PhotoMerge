"""Type detection by magic bytes.  The extension is not the type (PLAN §0).

The real export contains three files with no extension at all that are QuickTime
MOV, `.MP` files that are MP4, and `X.MP.jpg` stills whose stem contains another
extension.  Classifying by suffix (the v0 script's `IMG_EXT`/`VID_EXT`, D13)
silently ignored 163 of them.
"""

from __future__ import annotations

import struct
from pathlib import Path

# ISO base media format brands.  HEIC and MP4 share a container; only the brand
# in the `ftyp` box separates a still from a movie.
_BMFF_IMAGE_BRANDS = {
    "heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs",
    "mif1", "msf1", "avif", "avis", "mia1", "miaf",
}
_BMFF_VIDEO_BRANDS = {
    "qt  ", "isom", "iso2", "iso4", "iso5", "iso6", "mp41", "mp42", "mp4v",
    "m4v ", "m4a ", "M4V ", "M4A ", "3gp4", "3gp5", "3gp6", "3g2a", "avc1",
    "mmp4", "MSNV", "NDSC", "NDSM", "NDSP", "dash", "cmf1",
}

MIME_KIND = {
    "image/jpeg": "image", "image/png": "image", "image/gif": "image",
    "image/bmp": "image", "image/webp": "image", "image/tiff": "image",
    "image/heic": "image", "image/heif": "image", "image/avif": "image",
    "image/x-canon-cr2": "image", "image/x-adobe-dng": "image",
    "video/quicktime": "video", "video/mp4": "video", "video/3gpp": "video",
    "video/x-msvideo": "video", "video/x-matroska": "video",
    "application/json": "sidecar", "text/xml": "sidecar",
}


def sniff(path: str | Path, head: bytes | None = None) -> tuple[str, str]:
    """Return `(kind, mime)` for a file.  `kind` is image | video | other.

    Reads at most the first 4 KiB.  Callers that already hold the head bytes
    (the scanner does) can pass them in to avoid a second open.
    """
    if head is None:
        try:
            with open(path, "rb") as f:
                head = f.read(4096)
        except OSError:
            return "other", ""
    mime = _mime(head, Path(path))
    return MIME_KIND.get(mime, "other"), mime


def _mime(b: bytes, path: Path) -> str:
    if len(b) < 12:
        return ""
    if b[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if b[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if b[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if b[:2] == b"BM":
        return "image/bmp"
    if b[:4] == b"RIFF":
        if b[8:12] == b"WEBP":
            return "image/webp"
        if b[8:12] == b"AVI ":
            return "video/x-msvideo"
    if b[:4] == b"\x1a\x45\xdf\xa3":
        return "video/x-matroska"
    if b[:4] in (b"II*\x00", b"MM\x00*"):
        return _tiff_flavour(b, path)
    if b[4:8] == b"ftyp":
        return _bmff(b)
    # A QuickTime file need not start with `ftyp`; some begin with a top-level
    # `moov`, `mdat`, `wide`, `free` or `skip` atom.
    if b[4:8] in (b"moov", b"mdat", b"wide", b"free", b"skip", b"pnot"):
        return "video/quicktime"
    if b[:1] in (b"{", b"[") or b[:5] == b"\xef\xbb\xbf{":
        return "application/json"
    if b[:5] == b"<?xml":
        return "text/xml"
    return ""


def _bmff(b: bytes) -> str:
    """Read the major brand and the compatible-brand list out of `ftyp`."""
    major = b[8:12].decode("latin-1")
    size = struct.unpack(">I", b[:4])[0]
    compat = []
    for off in range(16, min(max(size, 16), len(b)) - 3, 4):
        compat.append(b[off : off + 4].decode("latin-1"))
    for brand in (major, *compat):
        if brand in _BMFF_IMAGE_BRANDS:
            return "image/avif" if brand.startswith("avi") else "image/heic"
    for brand in (major, *compat):
        if brand in _BMFF_VIDEO_BRANDS:
            if brand.startswith("3g"):
                return "video/3gpp"
            return "video/quicktime" if brand == "qt  " else "video/mp4"
    # Unknown brand: an ISO-BMFF file is far more often a movie than a still.
    return "video/mp4"


def _tiff_flavour(b: bytes, path: Path) -> str:
    """TIFF, or a raw format wearing TIFF's clothes."""
    if b[:4] == b"II*\x00" and b[8:10] == b"CR":
        return "image/x-canon-cr2"
    if path.suffix.lower() in (".dng",):
        return "image/x-adobe-dng"
    return "image/tiff"
