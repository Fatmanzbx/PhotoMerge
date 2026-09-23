"""The extension is not the type (D13, PLAN §0)."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from photomerge.sniff import sniff
from tests import fixtures


def test_extensionless_mov_is_a_video(tmp_path):
    # Three files in the real export have no extension at all and are QuickTime.
    path = fixtures.write_mov(tmp_path / "IMG_7747")
    assert sniff(path) == ("video", "video/quicktime")


def test_motion_photo_mp_is_mp4(tmp_path):
    # `.MP` is in neither IMG_EXT nor VID_EXT; v0 ignored 163 such files.
    path = fixtures.write_mp4(tmp_path / "PXL_20241124_164009882.MP")
    assert sniff(path) == ("video", "video/mp4")


def test_motion_photo_still_is_an_image(tmp_path):
    # `X.MP.jpg` has another extension inside its stem.
    path = fixtures.write_jpeg(tmp_path / "PXL_20241212_142659379.MP.jpg")
    assert sniff(path) == ("image", "image/jpeg")


def test_jpeg_lying_about_its_extension(tmp_path):
    path = fixtures.write_jpeg(tmp_path / "actually_a_jpeg.png")
    assert sniff(path) == ("image", "image/jpeg")


def test_heic_and_mp4_share_a_container_but_not_a_kind(tmp_path):
    heic = tmp_path / "x.heic"
    heic.write_bytes(b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00heicmif1" + b"\x00" * 32)
    assert sniff(heic) == ("image", "image/heic")
    assert sniff(fixtures.write_mp4(tmp_path / "y.mp4")) == ("video", "video/mp4")


def test_sidecars_and_junk_are_not_media(tmp_path):
    j = tmp_path / "a.json"
    j.write_text('{"title": "x"}')
    assert sniff(j)[0] == "sidecar"
    junk = tmp_path / "notes.bin"
    junk.write_bytes(b"\x00" * 64)
    assert sniff(junk)[0] == "other"
