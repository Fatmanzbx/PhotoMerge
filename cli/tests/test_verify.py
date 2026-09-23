"""Tier D — the cascade that stands between "looks alike" and "is the same photo".

A missed duplicate costs disk. A false merge loses a photo forever. Every test
here is written from that asymmetry: the failure worth preventing is CONFIRM on a
pair that is not one photo, and REVIEW is always an acceptable answer.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from photomerge import imagehash
from photomerge.verify import (
    BURST, CONFIRM, REJECT, REVIEW, Facts, haversine_km, verify,
)
from tests import fixtures

WASHINGTON = (38.8911, -77.0168)
TOKYO = (35.6762, 139.6503)


def facts(path: Path, **kw) -> Facts:
    with imagehash.open_oriented(path) as im:
        width, height = im.size
        d, p = imagehash.dhash64(im), imagehash.phash256(im)
    base = dict(id=abs(hash(str(path))) % 10**6, path=str(path), width=width,
                height=height, dhash64=d, phash256=p)
    return Facts(**(base | kw))


# --------------------------------------------------------- confirmations


def test_a_recompressed_copy_is_the_same_photo(tmp_path):
    image = fixtures.photo_image()
    a = facts(fixtures.write_jpeg(tmp_path / "a.jpg", image, quality=95))
    b = facts(fixtures.write_jpeg(tmp_path / "b.jpg", image, quality=60))
    verdict = verify(a, b)
    assert verdict.outcome == CONFIRM, verdict.reason


def test_a_downscaled_stripped_copy_is_the_same_photo(tmp_path):
    image = fixtures.photo_image()
    a = facts(fixtures.write_jpeg(tmp_path / "a.jpg", image))
    small = image.resize((240, 180))
    b = facts(fixtures.write_jpeg(tmp_path / "b.jpg", small))
    verdict = verify(a, b)
    assert verdict.outcome == CONFIRM, verdict.reason


def test_the_capture_fingerprint_decides_without_touching_pixels(tmp_path):
    image = fixtures.photo_image()
    shared = dict(make="Google", model="Pixel 9", exposure_key="0.002/1.7/53",
                  datetime_utc="2024-11-27T16:48:17+00:00")
    a = facts(fixtures.write_jpeg(tmp_path / "a.jpg", image), **shared)
    b = facts(fixtures.write_jpeg(tmp_path / "b.jpg", image, quality=60), **shared)
    verdict = verify(a, b, pixels=False)
    assert verdict.outcome == CONFIRM
    assert verdict.checks["fingerprint"] is True


# ------------------------------------------------------- separation guards


def test_the_same_scene_a_day_apart_is_two_photos(tmp_path):
    """§3.1-D5. The stronger the visual match, the more this guard matters."""
    image = fixtures.photo_image()
    a = facts(fixtures.write_jpeg(tmp_path / "a.jpg", image),
              datetime_utc="2024-11-27T16:48:17+00:00")
    b = facts(fixtures.write_jpeg(tmp_path / "b.jpg", image),
              datetime_utc="2024-11-29T16:48:17+00:00")
    verdict = verify(a, b)
    assert verdict.outcome == REJECT and "h apart" in verdict.reason


def test_the_same_scene_in_two_cities_is_two_photos(tmp_path):
    image = fixtures.photo_image()
    a = facts(fixtures.write_jpeg(tmp_path / "a.jpg", image), gps=WASHINGTON)
    b = facts(fixtures.write_jpeg(tmp_path / "b.jpg", image), gps=TOKYO)
    verdict = verify(a, b)
    assert verdict.outcome == REJECT and "km apart" in verdict.reason


def test_nearby_locations_do_not_trip_the_guard(tmp_path):
    image = fixtures.photo_image()
    nearby = (WASHINGTON[0] + 0.002, WASHINGTON[1])   # ~220 m
    a = facts(fixtures.write_jpeg(tmp_path / "a.jpg", image), gps=WASHINGTON)
    b = facts(fixtures.write_jpeg(tmp_path / "b.jpg", image), gps=nearby)
    assert verify(a, b).outcome == CONFIRM


def test_haversine_is_right_about_a_known_distance():
    assert 10_800 < haversine_km(WASHINGTON, TOKYO) < 11_200


# ----------------------------------------------------------- flat images


def test_two_screenshots_differing_in_one_digit_stay_apart(tmp_path):
    """The canonical false-merge hazard, and 10.9% of this library is in the
    population that reaches it (PLAN §13)."""
    a = facts(fixtures.write_jpeg(tmp_path / "a.jpg", fixtures.flat_image(label="1")))
    b = facts(fixtures.write_jpeg(tmp_path / "b.jpg", fixtures.flat_image(label="7")))
    verdict = verify(a, b)
    assert verdict.outcome != CONFIRM, verdict.reason


def test_flat_images_are_judged_by_local_difference_not_global(tmp_path):
    """Two frames that differ only by a global grey level are one image for any
    practical purpose and do merge. What must *not* merge is a pair differing in
    one small region — the screenshot case above — and that is why the tile grid
    is fine-grained rather than the threshold being strict."""
    a = facts(fixtures.write_jpeg(tmp_path / "a.jpg", fixtures.flat_image(shade=235)))
    b = facts(fixtures.write_jpeg(tmp_path / "b.jpg", fixtures.flat_image(shade=236)))
    assert verify(a, b).outcome == CONFIRM

    # ... and a localised change of the same magnitude does not.
    c = facts(fixtures.write_jpeg(tmp_path / "c.jpg", fixtures.flat_image(label="100")))
    d = facts(fixtures.write_jpeg(tmp_path / "d.jpg", fixtures.flat_image(label="108")))
    assert verify(c, d).outcome != CONFIRM


def test_a_flat_image_is_recognised_as_flat(tmp_path):
    flat = facts(fixtures.write_jpeg(tmp_path / "flat.jpg", fixtures.flat_image()))
    busy = facts(fixtures.write_jpeg(tmp_path / "busy.jpg", fixtures.photo_image()))
    checks = {}
    from photomerge.verify import _is_flat
    assert _is_flat(flat, checks, "a") is True
    assert _is_flat(busy, checks, "b") is False


# ---------------------------------------------------------------- bursts


def test_burst_frames_are_tagged_rather_than_collapsed_as_copies(tmp_path):
    """Same camera, same instant, same exposure — but not the same frame.
    Collapsing these by pixel count would keep a blurry one (§3.2), so they are
    labelled for M4's sharpness-based selection instead of confirmed here."""
    image = fixtures.photo_image()
    shared = dict(make="Apple", model="iPhone XR", exposure_key="0.004/1.8/40")
    a = facts(fixtures.write_jpeg(tmp_path / "a.jpg", image),
              datetime_utc="2024-11-27T16:48:17+00:00", **shared)
    b = facts(fixtures.write_jpeg(tmp_path / "b.jpg", fixtures.shifted_image(image)),
              datetime_utc="2024-11-27T16:48:18+00:00", **shared)
    verdict = verify(a, b)
    assert verdict.outcome == BURST, verdict.reason


# ------------------------------------------------------------ C2, crops


def test_a_crop_is_a_variant_not_a_duplicate(tmp_path):
    image = fixtures.photo_image()
    a = facts(fixtures.write_jpeg(tmp_path / "a.jpg", image))
    cropped = image.crop((0, 0, 380, 260))
    b = facts(fixtures.write_jpeg(tmp_path / "b.jpg", cropped))
    verdict = verify(a, b)
    assert verdict.outcome != CONFIRM, verdict.reason


def test_genuinely_different_photos_are_rejected(tmp_path):
    a = facts(fixtures.write_jpeg(tmp_path / "a.jpg", fixtures.photo_image(seed=1)))
    b = facts(fixtures.write_jpeg(tmp_path / "b.jpg", fixtures.photo_image(seed=2)))
    assert verify(a, b).outcome == REJECT


def test_an_unreadable_file_escalates_rather_than_merging(tmp_path):
    a = facts(fixtures.write_jpeg(tmp_path / "a.jpg", fixtures.photo_image()))
    broken = tmp_path / "broken.jpg"
    broken.write_bytes(b"\xff\xd8\xff" + b"\x00" * 200)
    b = Facts(id=999, path=str(broken), width=a.width, height=a.height,
              dhash64=a.dhash64, phash256=a.phash256)
    assert verify(a, b).outcome in (REVIEW, REJECT)
