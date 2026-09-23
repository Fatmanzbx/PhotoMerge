"""Stage 3 — the two certain tiers, companions, and who wins a cluster."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from photomerge.catalog import open_catalog
from photomerge.cluster import ClusterStats, File, _pair_companions, choose_canonical, cluster
from photomerge.extract import extract
from photomerge.scan import scan
from tests import fixtures


def build(root: Path, *sources: str) -> list[Path]:
    return [root / s for s in sources]


def catalog_for(tmp_path: Path, sources: list[Path]):
    db = open_catalog(tmp_path / "catalog.sqlite")
    scan(db, sources)
    extract(db, workers=2)
    return db


def outcomes(db) -> dict[str, str]:
    return {
        Path(r["path"]).name: r["outcome"]
        for r in db.execute(
            "SELECT f.path, d.outcome FROM decision d JOIN file f ON f.id = d.file_id")
    }


# ------------------------------------------------------------ the two tiers


def test_byte_identical_copies_across_sources_become_one_asset(tmp_path):
    image = fixtures.noise_image()
    a = fixtures.write_jpeg(tmp_path / "mac" / "IMG_1.jpg", image)
    b = tmp_path / "gphotos" / "IMG_1.jpg"
    b.parent.mkdir(parents=True)
    b.write_bytes(a.read_bytes())

    db = catalog_for(tmp_path, [tmp_path / "mac", tmp_path / "gphotos"])
    stats = cluster(db)
    assert (stats.clusters, stats.duplicates) == (1, 1)
    assert db.execute("SELECT method FROM cluster").fetchone()["method"] == "exact"


def test_same_pixels_in_a_different_container_become_one_asset(tmp_path):
    """PLAN §3.1-B — same image, different container or metadata."""
    image = fixtures.noise_image()
    src = tmp_path / "mac"
    src.mkdir()
    image.save(src / "a.png", "PNG")
    image.save(src / "b.bmp", "BMP")

    db = catalog_for(tmp_path, [src])
    stats = cluster(db)
    assert (stats.clusters, stats.duplicates) == (1, 1)
    assert db.execute("SELECT method FROM cluster").fetchone()["method"] == "pixel"
    # PNG outranks BMP on format tier, so it is the one kept.
    kept = db.execute(
        "SELECT f.path FROM member m JOIN file f ON f.id=m.file_id "
        "WHERE m.role='canonical'").fetchone()["path"]
    assert Path(kept).name == "a.png"


def test_the_certain_tiers_alone_never_merge_a_look_alike(tmp_path):
    """`--no-perceptual` has no threshold to be wrong about: it merges equal
    bytes and equal pixels, and nothing else, however similar."""
    src = tmp_path / "mac"
    fixtures.write_jpeg(src / "a.jpg", fixtures.photo_image(seed=1))
    fixtures.write_jpeg(src / "b.jpg", fixtures.photo_image(seed=2))
    fixtures.write_jpeg(src / "c.jpg", fixtures.photo_image(seed=1), quality=40)

    db = catalog_for(tmp_path, [src])
    assert cluster(db, perceptual=False).clusters == 3


def test_the_perceptual_tier_merges_a_recompression_but_not_two_photos(tmp_path):
    """M3's whole job, and its whole risk, in one library: the re-encode is the
    same photo and must merge; the other two are not and must not."""
    src = tmp_path / "mac"
    fixtures.write_jpeg(src / "a.jpg", fixtures.photo_image(seed=1))
    fixtures.write_jpeg(src / "b.jpg", fixtures.photo_image(seed=2))
    fixtures.write_jpeg(src / "c.jpg", fixtures.photo_image(seed=1), quality=40)

    db = catalog_for(tmp_path, [src])
    stats = cluster(db)
    assert stats.clusters == 2, "a.jpg and c.jpg are one photo; b.jpg is another"
    assert stats.verified >= 1
    sizes = sorted(r[0] for r in db.execute(
        "SELECT COUNT(*) FROM member GROUP BY cluster_id"))
    assert sizes == [1, 2]


# ------------------------------------------------------- canonical selection


def make(**kw) -> File:
    base = dict(id=1, path="/x/a.jpg", rel_path="a.jpg", source="mac",
                source_priority=0, size=1000, ext=".jpg", kind="image",
                mime="image/jpeg", sha256="a" * 64, pixel_hash="p", stream_hash=None, sharpness=None,
                dhash64=None, phash256=None, make=None, model=None,
                exposure_key=None, width=100, height=100, content_id=None)
    return File(**(base | kw))


def test_format_tier_outranks_source_priority(tmp_path):
    """The 1,671-stem case (PLAN §0): Google holds the HEIC original and Apple
    only a JPEG transcode.  Ranking by source first picks the worse file at
    scale, so `--src` order is deliberately step 4."""
    heic_from_low_priority = make(id=1, mime="image/heic", source="gphotos",
                                  source_priority=9, size=800, sha256="b" * 64)
    jpeg_from_top_priority = make(id=2, mime="image/jpeg", source="mac",
                                  source_priority=0, size=1200, sha256="a" * 64)
    winner, why = choose_canonical([jpeg_from_top_priority, heic_from_low_priority])
    assert winner.mime == "image/heic"
    assert "more original format" in why


def test_pixel_count_outranks_everything(tmp_path):
    small_original = make(id=1, mime="image/heic", width=100, height=100)
    large_transcode = make(id=2, mime="image/jpeg", width=400, height=400,
                           sha256="b" * 64)
    winner, why = choose_canonical([small_original, large_transcode])
    assert winner.id == 2 and "more pixels" in why


def test_near_equal_pixel_counts_are_a_tie_and_fall_through_to_format():
    # Within 2%, so the 1-pixel edge must not decide it.
    barely_bigger_jpeg = make(id=1, mime="image/jpeg", width=1000, height=1000)
    heic = make(id=2, mime="image/heic", width=999, height=999, sha256="b" * 64)
    winner, why = choose_canonical([barely_bigger_jpeg, heic])
    assert winner.mime == "image/heic" and "more original format" in why


def test_source_priority_breaks_a_genuine_tie():
    winner, why = choose_canonical([
        make(id=1, source="gphotos", source_priority=1, sha256="a" * 64),
        make(id=2, source="mac", source_priority=0, sha256="b" * 64),
    ])
    assert winner.source == "mac" and "source priority" in why


def test_selection_is_deterministic_when_nothing_distinguishes_them():
    a = make(id=1, sha256="b" * 64)
    b = make(id=2, sha256="a" * 64)
    assert choose_canonical([a, b])[0].sha256 == "a" * 64
    assert choose_canonical([b, a])[0].sha256 == "a" * 64


# ----------------------------------------------------------------- companions


def pair(files: list[File]) -> dict[int, tuple[int, str]]:
    return _pair_companions({f.id: f for f in files}, ClusterStats())


def test_motion_photo_pairing_is_a_prefix_not_a_stem(tmp_path):
    """D14 — the movie's whole name is a prefix of the still's, so keying on
    stems splits all 150 pairs in the real export."""
    still = make(id=1, path="/x/PXL_1.MP.jpg", mime="image/jpeg")
    movie = make(id=2, path="/x/PXL_1.MP", ext=".mp", kind="video",
                 mime="video/mp4", sha256="b" * 64)
    assert pair([still, movie]) == {2: (1, "motion_photo")}


def test_live_photo_pairs_on_content_id_across_sources(tmp_path):
    """D6 — the v0 rule keyed on (directory, stem) and cannot reach these."""
    still = make(id=1, path="/mac/IMG_4107.jpeg", source="mac", content_id="ABC")
    movie = make(id=2, path="/gphotos/IMG_8787.MP4", source="gphotos", kind="video",
                 ext=".mp4", mime="video/mp4", content_id="ABC", sha256="b" * 64)
    assert pair([still, movie]) == {2: (1, "content_id")}


def test_content_id_prefers_the_still_in_its_own_directory():
    local = make(id=1, path="/gphotos/IMG_1.jpg", source="gphotos", content_id="ABC")
    remote = make(id=2, path="/mac/IMG_9.jpg", source="mac", content_id="ABC",
                  sha256="c" * 64)
    movie = make(id=3, path="/gphotos/IMG_1.MOV", source="gphotos", kind="video",
                 ext=".mov", mime="video/quicktime", content_id="ABC", sha256="b" * 64)
    assert pair([remote, local, movie])[3][0] == 1


def test_a_movie_with_no_still_is_an_ordinary_video():
    movie = make(id=1, path="/x/VID_1.mp4", kind="video", ext=".mp4",
                 mime="video/mp4")
    assert pair([movie]) == {}


def test_the_companion_follows_the_canonical(tmp_path):
    """A Live Photo pair split so the better still has no movie of its own: the
    movie still has to survive, or the pair is silently downgraded to a still."""
    image = fixtures.noise_image()
    mac, goog = tmp_path / "mac", tmp_path / "gphotos"
    fixtures.write_jpeg(mac / "IMG_1.jpg", image)            # no movie beside it
    still = fixtures.write_jpeg(goog / "IMG_1.jpg", image)   # identical bytes...
    fixtures.write_mov(goog / "IMG_1.mov")                   # ...but this one has one
    Path(goog / "IMG_1.jpg").write_bytes(Path(mac / "IMG_1.jpg").read_bytes())

    db = catalog_for(tmp_path, [mac, goog])
    cluster(db)
    got = outcomes(db)
    assert got["IMG_1.mov"] == "companion"
    roles = {r["role"] for r in db.execute("SELECT role FROM member")}
    assert roles == {"canonical", "duplicate", "companion"}
    # One cluster, so the movie was adopted rather than orphaned.
    assert db.execute("SELECT COUNT(*) FROM cluster").fetchone()[0] == 1


def test_companion_movies_that_differ_go_to_review_not_the_bin(tmp_path):
    """Two stills being the same image does not prove their movies are.
    'Probably the same capture' is not a licence to delete half a photo."""
    image = fixtures.noise_image()
    mac, goog = tmp_path / "mac", tmp_path / "gphotos"
    fixtures.write_jpeg(mac / "IMG_1.jpg", image)
    fixtures.write_mov(mac / "IMG_1.mov")
    (goog).mkdir(parents=True, exist_ok=True)
    (goog / "IMG_1.jpg").write_bytes((mac / "IMG_1.jpg").read_bytes())
    different = fixtures.write_mov(goog / "IMG_1.mov")
    different.write_bytes(different.read_bytes() + b"\xff" * 32)  # a different movie

    db = catalog_for(tmp_path, [mac, goog])
    stats = cluster(db)
    assert stats.review == 1
    assert sum(1 for v in outcomes(db).values() if v == "review") == 1


# ------------------------------------------------------- standing properties


def test_every_input_file_is_accounted_for(tmp_path):
    """PLAN §8's standing property: no input photo is unrepresented in the
    output, modulo intended dedup."""
    image = fixtures.noise_image()
    mac, goog = tmp_path / "mac", tmp_path / "gphotos"
    fixtures.write_jpeg(mac / "a.jpg", image)
    fixtures.write_jpeg(mac / "b.jpg", fixtures.noise_image(seed=7))
    (goog).mkdir(parents=True)
    (goog / "a.jpg").write_bytes((mac / "a.jpg").read_bytes())
    fixtures.write_mov(goog / "a.mov")

    db = catalog_for(tmp_path, [mac, goog])
    cluster(db)
    extracted = db.execute("SELECT COUNT(*) FROM file WHERE status='extracted'").fetchone()[0]
    decided = db.execute("SELECT COUNT(DISTINCT file_id) FROM decision").fetchone()[0]
    membered = db.execute("SELECT COUNT(DISTINCT file_id) FROM member").fetchone()[0]
    assert extracted == decided == membered
    assert db.execute(
        "SELECT COUNT(*) FROM (SELECT file_id FROM decision GROUP BY file_id "
        "HAVING COUNT(*) > 1)").fetchone()[0] == 0


def test_clustering_twice_changes_nothing(tmp_path):
    image = fixtures.noise_image()
    src = tmp_path / "mac"
    fixtures.write_jpeg(src / "a.jpg", image)
    (src / "b.jpg").write_bytes((src / "a.jpg").read_bytes())

    db = catalog_for(tmp_path, [src])
    first = cluster(db)
    kept = outcomes(db)
    second = cluster(db)
    assert (first.clusters, first.duplicates) == (second.clusters, second.duplicates)
    assert kept == outcomes(db)


def test_video_duplicates_are_counted_apart_from_photos(tmp_path):
    """§5: every video is copied out and duplicates are flagged, not deleted, so
    they must never be folded into the 'removable' number."""
    src = tmp_path / "mac"
    a = fixtures.write_mov(src / "VID_1.mov")
    (src / "VID_2.mov").write_bytes(a.read_bytes())

    db = catalog_for(tmp_path, [src])
    stats = cluster(db)
    assert (stats.duplicates, stats.video_duplicates) == (0, 1)
    assert stats.freed_bytes == 0 and stats.video_freed_bytes > 0


def test_a_burst_collapses_by_sharpness_and_stays_recoverable(tmp_path):
    """§3.2: collapsing a burst is allowed, but it has to be *deliberate* — the
    kept frame chosen by sharpness rather than by pixel count, the other frames
    recorded as siblings rather than discarded as duplicates, and reversible."""
    src = tmp_path / "mac"
    base = fixtures.photo_image()
    first = fixtures.write_jpeg(src / "IMG_1.jpg", base)
    second = fixtures.write_jpeg(src / "IMG_2.jpg", fixtures.shifted_image(base))
    for path in (first, second):
        fixtures.exiftool_set(
            path, "-EXIF:Make=Apple", "-EXIF:Model=iPhone XR",
            "-EXIF:DateTimeOriginal=2024:11:27 11:48:17",
            "-EXIF:OffsetTimeOriginal=-05:00",
            "-EXIF:ExposureTime=0.004", "-EXIF:FNumber=1.8", "-EXIF:ISO=40")

    db = catalog_for(tmp_path, [src])
    stats = cluster(db)
    assert stats.clusters == 1 and stats.burst_siblings == 1
    roles = dict(db.execute(
        "SELECT role, COUNT(*) FROM member GROUP BY role").fetchall())
    assert roles == {"canonical": 1, "burst_sibling": 1}
    kept = db.execute("SELECT reason FROM decision WHERE outcome='canonical'"
                      ).fetchone()["reason"]
    assert "sharpest frame" in kept

    # ... and --keep-bursts leaves both frames as their own assets.
    stats = cluster(db, keep_bursts=True)
    assert stats.clusters == 2 and stats.burst_siblings == 0


def test_a_perceptual_duplicate_is_not_described_as_pixel_identical(tmp_path):
    """The `reason` column is what a reader audits a merge with, so it has to
    name the tier that actually decided — a re-encode is not the same pixels."""
    src = tmp_path / "mac"
    fixtures.write_jpeg(src / "a.jpg", fixtures.photo_image())
    fixtures.write_jpeg(src / "c.jpg", fixtures.photo_image(), quality=40)

    db = catalog_for(tmp_path, [src])
    cluster(db)
    reason = db.execute(
        "SELECT reason FROM decision WHERE outcome='duplicate'").fetchone()["reason"]
    assert "same pixels" not in reason and "same bytes" not in reason
    assert "confirmed the same photo" in reason


def test_an_edit_is_kept_as_its_own_asset_not_dropped(tmp_path):
    """D9: an edit is the same photograph deliberately changed. Dropping it for
    resembling its origin loses work the photographer did, and it is the kind of
    loss nobody notices."""
    src = tmp_path / "mac"
    base = fixtures.photo_image()
    fixtures.write_jpeg(src / "PXL_1.jpg", base)
    # Same scene, visibly reworked — what an exposure edit looks like.
    import numpy as np
    from PIL import Image
    brighter = Image.fromarray(
        np.clip(np.asarray(base).astype(np.int16) + 18, 0, 255).astype(np.uint8), "RGB")
    fixtures.write_jpeg(src / "PXL_1-edited.jpg", brighter)

    db = catalog_for(tmp_path, [src])
    stats = cluster(db)
    assert stats.clusters == 1, "the edit belongs with its origin"
    assert stats.variants == 1
    roles = dict(db.execute("SELECT role, COUNT(*) FROM member GROUP BY role").fetchall())
    assert roles == {"canonical": 1, "variant": 1}
    # It points at what it was derived from, and it is not counted as removable.
    assert db.execute(
        "SELECT derived_from FROM member WHERE role='variant'").fetchone()[0] is not None
    assert stats.duplicates == 0 and stats.freed_bytes == 0


def test_a_re_encode_is_not_mistaken_for_an_edit(tmp_path):
    """Every one of the 85 `_Original` pairs in the real library is a re-encode
    at SSIM 0.999, not an edit. Only the naming says which is which."""
    src = tmp_path / "mac"
    image = fixtures.photo_image()
    fixtures.write_jpeg(src / "IMG_1.jpg", image, quality=95)
    fixtures.write_jpeg(src / "IMG_1_Original.jpg", image, quality=70)

    db = catalog_for(tmp_path, [src])
    stats = cluster(db)
    assert stats.variants == 0 and stats.duplicates == 1


def test_a_still_keeps_only_one_companion_and_content_id_decides(tmp_path):
    """A long unrelated video that merely shares a name was being attached
    alongside the real motion clip, and — sorting first — took the primary
    output name, so the pair became a still plus a 36-second video while the
    genuine 2-second motion was left over and failed to import."""
    still = make(id=1, path="/x/IMG_1.HEIC", mime="image/heic", content_id="ABC")
    motion = make(id=2, path="/x/IMG_1 (2).mov", ext=".mov", kind="video",
                  mime="video/quicktime", content_id="ABC", size=1_500_000,
                  sha256="b" * 64)
    unrelated = make(id=3, path="/x/IMG_1.mov", ext=".mov", kind="video",
                     mime="video/quicktime", content_id=None, size=32_000_000,
                     sha256="c" * 64)
    paired = pair([still, motion, unrelated])
    assert paired == {2: (1, "content_id")}, "only the identified motion clip"
    assert 3 not in paired, "the unrelated video goes back to being its own asset"


def test_when_both_rivals_match_the_shorter_one_wins(tmp_path):
    """Two copies of the same motion clip from different sources both carry the
    identifier; either is correct, so the choice just has to be deterministic."""
    still = make(id=1, path="/x/IMG_5.HEIC", mime="image/heic", content_id="ABC")
    small = make(id=2, path="/x/IMG_5.MP4", ext=".mp4", kind="video",
                 mime="video/mp4", content_id="ABC", size=4_266_750, sha256="b" * 64)
    large = make(id=3, path="/x/IMG_5 (2).mov", ext=".mov", kind="video",
                 mime="video/quicktime", content_id="ABC", size=4_266_896,
                 sha256="c" * 64)
    paired = pair([still, small, large])
    assert list(paired) == [2]
