"""Dates in filenames — weak evidence, but better than mtime (D11)."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from photomerge.filenames import datetime_from_name, folder_claims


@pytest.mark.parametrize("name,field,value", [
    # A wall clock, with no zone attached — Pixel, Android, screenshots.
    ("PXL_20250720_161254963.jpg", "datetime_local", "2025-07-20T16:12:54"),
    ("IMG_20240101_120000.jpg", "datetime_local", "2024-01-01T12:00:00"),
    ("VID_20241212_105113.mp4", "datetime_local", "2024-12-12T10:51:13"),
    ("Screenshot_20190101-120000.png", "datetime_local", "2019-01-01T12:00:00"),
    ("Screenshot 2024-01-01 at 12.00.00.png", "datetime_local", "2024-01-01T12:00:00"),
    ("IMG-20240101-WA0001.jpg", "datetime_local", "2024-01-01T00:00:00"),
    # A Unix epoch — an instant, unambiguous.  WeChat and Android video apps.
    ("mmexport1734645642.jpg", "datetime_utc", "2024-12-19T22:00:42+00:00"),
    ("Video1688440375537.mp4", "datetime_utc", "2023-07-04T03:12:55.537000+00:00"),
])
def test_recognised_patterns(name, field, value):
    assert datetime_from_name(name) == (field, value)


@pytest.mark.parametrize("name", [
    "IMG_0899.HEIC",          # a plain counter is not a date
    "DSC_0042.jpg",
    "-466b732327e8e5fa.jpeg",  # a hash-named file
    "IMG_18000101_120000.jpg",  # before any digital camera existed
])
def test_names_that_say_nothing_about_time(name):
    assert datetime_from_name(name) is None


def test_takeout_year_folders_are_weak_and_albums_are_not():
    assert folder_claims(("Photos from 2019",)) == [("year", "2019", 0.3)]
    # Album membership survives the export only in the folder name, and
    # `osxphotos import` can put it back (README §5b).
    assert folder_claims(("Holiday",)) == [("album", "Holiday", 0.8)]
