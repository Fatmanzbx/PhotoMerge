"""Stage 5c — the remux and the pairing, both of which fail silently untested."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from photomerge.livephotos import LiveStats, _extract_motion
from tests import fixtures

makelive = pytest.importorskip("makelive")


def frames(path: Path) -> int:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-count_frames", "-show_entries", "stream=nb_read_frames",
         "-of", "csv=p=0", str(path)], capture_output=True, text=True).stdout
    return int(out.strip().rstrip(",") or 0)


def test_the_remux_keeps_the_motion_and_only_the_motion(tmp_path):
    """PLAN §5d's recipe was `ffmpeg -i X.MP -c copy X.mov`. On a real Motion
    Photo that kept the single-frame stream instead of the clip, turning 3.7 MB
    into 198 KB with the motion silently gone — ffmpeg selects by resolution and
    the embedded still is the larger of the two. Naming the stream is the fix.

    (The naive command's behaviour depends on the real container's stream
    properties and is not reproducible from a synthesised file, so what is
    asserted here is what this function guarantees: the clip survives, and the
    extra streams do not.)"""
    source = fixtures.write_motion_photo(tmp_path / "PXL_1.MP", frames=40)
    target = tmp_path / "PXL_1.mov"
    stats = LiveStats()
    assert _extract_motion(source, target, stats) is True
    assert stats.failures == []
    assert frames(target) > 30, "the clip, not one frame of it"

    streams = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "stream=codec_type",
         "-of", "csv=p=0", str(target)], capture_output=True, text=True).stdout
    assert streams.strip().splitlines() == ["video"], "one video stream, nothing else"


def test_a_remux_that_lost_the_motion_is_refused(tmp_path):
    """The guard matters more than the fix: replacing a clip with one frame of
    it is worse than leaving it alone, and nothing downstream would notice."""
    source = fixtures.write_motion_photo(tmp_path / "PXL_2.MP", frames=40)
    target = tmp_path / "PXL_2.mov"
    stats = LiveStats()

    import photomerge.livephotos as L
    real = L.subprocess.run

    def shrinking(cmd, **kw):
        result = real(cmd, **kw)
        # Simulate a remux that produced something implausibly small.
        Path(cmd[-1]).write_bytes(b"\x00" * 64)
        return result

    L.subprocess.run = shrinking
    try:
        assert _extract_motion(source, target, stats) is False
    finally:
        L.subprocess.run = real
    assert not target.exists()
    assert "refusing to replace the clip" in stats.failures[0]


def test_a_paired_still_and_movie_read_back_as_a_live_photo(tmp_path):
    """exiftool cannot write the identifier onto a plain JPEG at all — it will
    not create an Apple MakerNotes block. This is delegated to `makelive`, and
    the result is checked rather than assumed."""
    still = fixtures.write_jpeg(tmp_path / "pair.jpg", fixtures.photo_image())
    movie = tmp_path / "pair.mov"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
                    "-i", "testsrc=duration=1:size=320x240:rate=15",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-f", "mov",
                    str(movie)], check=True)
    assert not makelive.is_live_photo_pair(still, movie)
    identifier = makelive.make_live_photo(still, movie)
    assert makelive.is_live_photo_pair(still, movie) == identifier


def test_exiftool_alone_cannot_do_this(tmp_path):
    """Kept as a standing check on the reason `makelive` is a dependency: if a
    future exiftool learns to write this, the extra dependency can go."""
    still = fixtures.write_jpeg(tmp_path / "s.jpg", fixtures.photo_image())
    subprocess.run(["exiftool", "-overwrite_original", "-q", "-m",
                    "-MakerNotes:ContentIdentifier=11111111-2222-3333-4444-555555555555",
                    str(still)], capture_output=True)
    back = subprocess.run(["exiftool", "-s3", "-ContentIdentifier", str(still)],
                          capture_output=True, text=True).stdout.strip()
    assert back == "", "exiftool still cannot create an Apple MakerNotes block"
