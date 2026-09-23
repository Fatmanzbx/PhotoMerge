"""Fingerprint properties — above all, that orientation is normalised (D4)."""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from photomerge.imagehash import dhash64, hamming, open_oriented, phash256, pixel_hash
from tests import fixtures

# EXIF Orientation 6 ("rotate 90° CW to display") is PIL's ROTATE_270.
ORIENTATION_6 = Image.Transpose.ROTATE_270


def test_tag_rotated_and_pixel_rotated_copies_hash_alike(tmp_path):
    """The same photo, rotated by a tag in one copy and in the pixels in another.

    v0 hashed the stored buffer, so these two never clustered and the library
    kept both forever.
    """
    base = fixtures.noise_image()
    tagged = tmp_path / "tagged.png"
    base.save(tagged, "PNG")
    fixtures.exiftool_set(tagged, "-EXIF:Orientation#=6")

    baked = tmp_path / "baked.png"
    base.transpose(ORIENTATION_6).save(baked, "PNG")

    assert pixel_hash(open_oriented(tagged)) == pixel_hash(open_oriented(baked))
    assert dhash64(open_oriented(tagged)) == dhash64(open_oriented(baked))


def test_orientation_survives_a_lossy_re_encode_at_the_dhash_tier(tmp_path):
    base = fixtures.noise_image()
    tagged = fixtures.write_jpeg(tmp_path / "tagged.jpg", base)
    fixtures.exiftool_set(tagged, "-EXIF:Orientation#=6")
    baked = fixtures.write_jpeg(tmp_path / "baked.jpg", base.transpose(ORIENTATION_6))
    wrong = fixtures.write_jpeg(tmp_path / "wrong.jpg",
                                base.transpose(Image.Transpose.ROTATE_90))

    assert hamming(dhash64(open_oriented(tagged)), dhash64(open_oriented(baked))) == 0
    # ... and the opposite rotation stays far away, so this is not a hash that
    # simply collapses everything.
    assert hamming(dhash64(open_oriented(tagged)), dhash64(open_oriented(wrong))) > 20


def test_same_pixels_in_a_different_container_are_pixel_identical(tmp_path):
    """PLAN §3.1-B: the Apple-original vs. Google-EXIF-stripped case."""
    base = fixtures.noise_image()
    a, b = tmp_path / "a.png", tmp_path / "b.bmp"
    base.save(a, "PNG")
    base.save(b, "BMP")
    assert pixel_hash(open_oriented(a)) == pixel_hash(open_oriented(b))


def test_different_photos_do_not_collide(tmp_path):
    a = fixtures.noise_image(seed=1)
    b = fixtures.noise_image(seed=2)
    assert pixel_hash(a) != pixel_hash(b)
    assert hamming(dhash64(a), dhash64(b)) > 10
    assert hamming(phash256(a), phash256(b)) > 40


def test_hash_widths_are_what_the_bk_tree_expects():
    im = fixtures.noise_image()
    assert len(dhash64(im)) == 8
    assert len(phash256(im)) == 32
