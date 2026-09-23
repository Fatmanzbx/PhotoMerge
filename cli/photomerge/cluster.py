"""Stage 3 — group files that are the same photo.

M2 ships only the two certain tiers (PLAN §3.1):

    A. exact  — equal sha256.      Same bytes.
    B. pixel  — equal pixel_hash.  Same decoded image, different container or
                                   metadata.

Both are exact-equality joins, so there is no threshold to tune and no way to
merge two photos that merely look alike.  The perceptual tier, which is where
this library's remaining duplicates actually live (§0), is M3.

Companions are resolved here rather than later because they change what a
"duplicate" even means: a Live Photo's movie is not a video that happens to
resemble another video, it is half of a still, and it moves with it.
"""

from __future__ import annotations

import sqlite3
import json
import re
from collections import defaultdict
from dataclasses import dataclass, field, fields
from pathlib import Path

from photomerge import sidecars
from photomerge import verify as tierd
from photomerge.bktree import candidate_pairs, to_int

# Most-original first.  A container that can only have been produced by
# re-encoding ranks below one that a camera writes directly.
FORMAT_TIER = {
    "image/x-adobe-dng": 5, "image/x-canon-cr2": 5, "image/tiff": 5,
    "image/heic": 4, "image/heif": 4, "image/avif": 4,
    "image/png": 3,
    "image/webp": 2,
    "image/jpeg": 1, "image/gif": 1, "image/bmp": 1,
}

# Two files whose pixel counts are within this of each other count as tied, so
# the decision falls through to format and size rather than to a rounding error.
PIXEL_TIE = 0.02


@dataclass
class File:
    id: int
    path: str
    rel_path: str
    source: str
    source_priority: int
    size: int
    ext: str
    kind: str
    mime: str
    sha256: str | None
    pixel_hash: str | None
    stream_hash: str | None
    sharpness: float | None
    dhash64: bytes | None
    phash256: bytes | None
    make: str | None
    model: str | None
    exposure_key: str | None
    width: int | None
    height: int | None
    content_id: str | None

    @property
    def pixels(self) -> int:
        return (self.width or 0) * (self.height or 0)

    @property
    def tier(self) -> int:
        return FORMAT_TIER.get(self.mime or "", 0)


@dataclass
class ClusterStats:
    files: int = 0
    clusters: int = 0
    duplicates: int = 0
    freed_bytes: int = 0
    video_duplicates: int = 0
    video_freed_bytes: int = 0
    companions: int = 0
    by_companion_rule: dict[str, int] = field(default_factory=dict)
    by_method: dict[str, int] = field(default_factory=dict)
    review: int = 0
    by_review_reason: dict[str, int] = field(default_factory=dict)
    burst_siblings: int = 0
    variants: int = 0
    candidates: int = 0
    video_candidates: int = 0
    video_verified: int = 0
    video_merged: int = 0
    verified: int = 0
    merged_by_tier: dict[str, int] = field(default_factory=dict)

    def bump(self, bucket: dict[str, int], key: str, n: int = 1) -> None:
        bucket[key] = bucket.get(key, 0) + n


def cluster(
    db: sqlite3.Connection,
    *,
    radius: int = 4,
    perceptual: bool = True,
    keep_bursts: bool = False,
    progress=None,
) -> ClusterStats:
    files = _load(db)
    stats = ClusterStats(files=len(files))

    companion_of = _pair_companions(files, stats)
    groups = _group(f for f in files.values() if f.id not in companion_of)
    methods = ["exact" if len({f.sha256 for f in g}) == 1 else "pixel" for g in groups]

    reviews: list[tuple[int, int, object]] = []
    evidence: dict[tuple[int, int], str] = {}
    if perceptual:
        groups, methods = _perceptual(db, files, groups, methods, radius, stats,
                                      reviews, progress, evidence, keep_bursts)
        groups, methods = _perceptual_video(db, files, groups, methods, stats,
                                            reviews, evidence)

    db.execute("BEGIN")
    try:
        db.execute("DELETE FROM member")
        db.execute("DELETE FROM cluster")
        db.execute("DELETE FROM decision")
        db.execute("DELETE FROM review")
        for members, method in zip(groups, methods):
            _record(db, stats, files, members, companion_of, method, evidence)
        for a, b, verdict in reviews:
            db.execute(
                "INSERT INTO review (file_a, file_b, verdict, reason, checks_json) "
                "VALUES (?,?,?,?,?)",
                (a, b, verdict.outcome, verdict.reason,
                 json.dumps(verdict.checks, default=float)))
            stats.review += 1
            stats.bump(stats.by_review_reason, verdict.reason.split(" (")[0][:60])
        if progress:
            progress(stats)
    finally:
        db.execute("COMMIT")
    return stats


# ----------------------------------------------------------- perceptual tier


def _perceptual(db, files, groups, methods, radius, stats, reviews, progress=None,
                evidence=None, keep_bursts=False):
    """Tier C candidates, tier D verification, then merge only what survives.

    The closure is taken over *confirmed* pairs alone. Taken over raw candidates
    at radius 6 it chains 217 distinct assets into one (PLAN §3.1-C); that is the
    failure this whole tier is arranged to avoid.
    """
    group_of = {f.id: i for i, g in enumerate(groups) for f in g}
    hashes = [(to_int(f.dhash64), f.id)
              for g in groups for f in g if f.dhash64 is not None]
    pairs = {(a, b) for a, b in candidate_pairs(hashes, radius)
             if group_of.get(a) != group_of.get(b)}
    stats.candidates = len(pairs)
    if not pairs:
        return groups, methods

    facts = _facts(db, {f for pair in pairs for f in pair}, files)
    # Verifying in file order keeps the decoded-thumbnail cache warm.
    confirmed: list[tuple[int, int]] = []
    burst_pairs: set[tuple[int, int]] = set()
    verdict_of: dict[tuple[int, int], object] = {}
    for a, b in sorted(pairs):
        if a not in facts or b not in facts:
            continue
        verdict = tierd.verify(facts[a], facts[b])
        stats.verified += 1
        if progress and stats.verified % 100 == 0:
            progress(stats)
        verdict_of[(a, b)] = verdict
        if verdict.outcome == tierd.BURST and keep_bursts:
            reviews.append((a, b, verdict))     # recorded, left as separate assets
        elif verdict.merges:
            confirmed.append((a, b))
            stats.bump(stats.merged_by_tier, verdict.outcome)
            if evidence is not None:
                evidence[(a, b)] = verdict.reason
            if verdict.outcome == tierd.BURST:
                burst_pairs.add((a, b))
        elif verdict.outcome == tierd.REVIEW:
            reviews.append((a, b, verdict))

    # Union the groups that confirmed pairs connect.
    parent = list(range(len(groups)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for a, b in confirmed:
        ra, rb = find(group_of[a]), find(group_of[b])
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    merged: dict[int, list] = {}
    merged_method: dict[int, str] = {}
    for i, g in enumerate(groups):
        root = find(i)
        merged.setdefault(root, []).extend(g)
        previous = merged_method.get(root, methods[i])
        merged_method[root] = previous if previous in ("perceptual", "burst") else methods[i]
    for a, b in confirmed:
        root = find(group_of[a])
        if (a, b) in burst_pairs:
            merged_method[root] = "burst"
        elif merged_method.get(root) != "burst":
            merged_method[root] = "perceptual"

    out_groups, out_methods = [], []
    for root, members in merged.items():
        out_groups.append(sorted(members, key=lambda f: f.id))
        out_methods.append(merged_method[root])
    return out_groups, out_methods


def _perceptual_video(db, files, groups, methods, stats, reviews, evidence):
    """Tier C/D for video: same length and moment, confirmed on sampled frames.

    Videos never entered the photo cascade — dHash and SSIM are image
    operations — so the first real run left 199 re-encoded copies standing,
    3.57 GB, in a library that was otherwise deduplicated.
    """
    from photomerge import videoverify as tierv

    group_of = {f.id: i for i, g in enumerate(groups) for f in g}
    times = _video_times(db)
    facts = {
        f.id: tierv.VideoFacts(
            id=f.id, path=f.path, duration=times.get(f.id, (None, None))[0],
            instant=times.get(f.id, (None, None))[1], width=f.width,
            height=f.height, size=f.size, stream_hash=f.stream_hash)
        for g in groups for f in g if f.kind == "video"}
    pairs = {p for p in tierv.candidates(list(facts.values()))
             if group_of.get(p[0]) != group_of.get(p[1])}
    stats.video_candidates = len(pairs)
    if not pairs:
        return groups, methods

    confirmed = []
    for a, b in sorted(pairs):
        verdict = tierv.verify(facts[a], facts[b])
        stats.video_verified += 1
        if verdict.merges:
            confirmed.append((a, b))
            evidence[(a, b)] = verdict.reason
        elif verdict.outcome == "review":
            reviews.append((a, b, verdict))

    parent = list(range(len(groups)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for a, b in confirmed:
        ra, rb = find(group_of[a]), find(group_of[b])
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)
        stats.video_merged += 1

    merged: dict[int, list] = {}
    merged_method: dict[int, str] = {}
    for i, g in enumerate(groups):
        root = find(i)
        merged.setdefault(root, []).extend(g)
        merged_method.setdefault(root, methods[i])
    for a, b in confirmed:
        merged_method[find(group_of[a])] = "video"
    out_groups, out_methods = [], []
    for root, members in merged.items():
        out_groups.append(sorted(members, key=lambda f: f.id))
        out_methods.append(merged_method[root])
    return out_groups, out_methods


def _video_times(db) -> dict[int, tuple[float | None, float | None]]:
    from datetime import datetime, timezone

    durations = {r["file_id"]: r["value"] for r in db.execute(
        "SELECT file_id, value FROM meta WHERE field = 'duration'")}
    out: dict[int, tuple[float | None, float | None]] = {}
    for r in db.execute(
        "SELECT file_id, value FROM meta WHERE field = 'datetime_utc' "
        "AND source IN ('quicktime', 'exif', 'google_json', 'filename')"
    ):
        try:
            when = datetime.fromisoformat(r["value"])
        except (TypeError, ValueError):
            continue
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        instant = when.timestamp()
        if r["file_id"] not in out or instant < out[r["file_id"]][1]:
            try:
                out[r["file_id"]] = (float(durations.get(r["file_id"], 0)) or None,
                                     instant)
            except (TypeError, ValueError):
                out[r["file_id"]] = (None, instant)
    return out


def _facts(db, ids: set[int], files) -> dict[int, "tierd.Facts"]:
    """Assemble what tier D needs: file columns plus the best dated and located
    claims each file makes on its own behalf."""
    times: dict[int, str] = {}
    places: dict[int, tuple[float, float]] = {}
    for r in db.execute(
        "SELECT file_id, field, value, source FROM meta "
        "WHERE field IN ('datetime_utc','gps') AND source IN ('exif','quicktime') "
        "ORDER BY confidence DESC"
    ):
        if r["field"] == "datetime_utc":
            times.setdefault(r["file_id"], r["value"])
        else:
            try:
                lat, _, lon = r["value"].partition(",")
                places.setdefault(r["file_id"], (float(lat), float(lon)))
            except ValueError:
                pass
    out = {}
    for fid in ids:
        f = files.get(fid)
        if f is None:
            continue
        out[fid] = tierd.Facts(
            id=f.id, path=f.path, width=f.width, height=f.height,
            dhash64=f.dhash64, phash256=f.phash256, make=f.make, model=f.model,
            exposure_key=f.exposure_key, datetime_utc=times.get(fid),
            gps=places.get(fid))
    return out


def _load(db) -> dict[int, File]:
    """Every extracted file, keyed by id.

    Built by keyword rather than by position: this tuple has grown twice as
    later tiers needed more columns, and a positional list silently shifts every
    field when it does.
    """
    columns = [f.name for f in fields(File)]
    rows = db.execute(
        f"SELECT {', '.join(columns)} FROM file "
        "WHERE status = 'extracted' ORDER BY id")
    return {r["id"]: File(**{c: r[c] for c in columns}) for r in rows}


# ----------------------------------------------------------------- companions


def _pair_companions(files: dict[int, File], stats: ClusterStats) -> dict[int, tuple[int, str]]:
    """`{video_id: (still_id, rule)}` — the movie half of a Live or Motion Photo.

    Rules run most-certain first and a video is claimed only once.
    """
    by_lower_path = {f.path.casefold(): f for f in files.values()}
    stills_by_content: dict[str, list[File]] = defaultdict(list)
    stills_by_dir_stem: dict[tuple[str, str], File] = {}
    for f in files.values():
        if f.kind != "image":
            continue
        if f.content_id:
            stills_by_content[f.content_id].append(f)
        p = Path(f.path)
        stills_by_dir_stem.setdefault((str(p.parent).casefold(), p.stem.casefold()), f)

    out: dict[int, tuple[int, str]] = {}
    for video in files.values():
        if video.kind != "video":
            continue

        # R1 — Google Motion Photo.  Not stem equality: the movie's whole name is
        # a prefix of the still's (`PXL_….MP` and `PXL_….MP.jpg`), which is why
        # a stem-keyed pairing splits all 150 of them (D14).
        if video.ext in (".mp", ".mp_original"):
            still = by_lower_path.get(f"{video.path}.jpg".casefold())
            if still and still.kind == "image":
                out[video.id] = (still.id, "motion_photo")
                stats.bump(stats.by_companion_rule, "motion_photo")
                continue

        # R2 — Apple Live Photo by ContentIdentifier.  This is the only rule that
        # can pair a still in one source with its movie in another (D6).
        if video.content_id:
            candidates = stills_by_content.get(video.content_id) or []
            if candidates:
                still = min(candidates, key=lambda s: (
                    s.source != video.source,
                    str(Path(s.path).parent).casefold() != str(Path(video.path).parent).casefold(),
                    s.id))
                out[video.id] = (still.id, "content_id")
                stats.bump(stats.by_companion_rule, "content_id")
                continue

        # R3 — same directory, same stem.  All the v0 script could do.
        p = Path(video.path)
        still = stills_by_dir_stem.get((str(p.parent).casefold(), p.stem.casefold()))
        if still:
            out[video.id] = (still.id, "dir_stem")
            stats.bump(stats.by_companion_rule, "dir_stem")

    # A still has at most one Live Photo companion. Left unenforced, a long
    # unrelated video that merely shares a name is attached alongside the real
    # motion clip, and — being first alphabetically — takes the primary name,
    # so the pair Photos builds is the still plus a 36-second video while the
    # genuine 2-second motion is left over. Measured: 7 stills drew two
    # companions, 2 of them wrongly.
    #
    # `content_id` is Apple's own assertion that a movie belongs to a still, so
    # it decides. A rival that does not carry the still's identifier is not a
    # companion at all and goes back to being its own asset.
    claimed: dict[int, list[int]] = defaultdict(list)
    for video_id, (still_id, _) in out.items():
        claimed[still_id].append(video_id)
    for still_id, videos in claimed.items():
        if len(videos) < 2:
            continue
        wanted = files[still_id].content_id
        def rank(vid: int):
            video = files[vid]
            return (
                0 if wanted and video.content_id == wanted else 1,
                0 if out[vid][1] == "motion_photo" else 1,
                video.size,          # a Live Photo movie is the short one
                vid,
            )
        keeper = min(videos, key=rank)
        for vid in videos:
            if vid == keeper:
                continue
            del out[vid]
            stats.bump(stats.by_companion_rule, "released: a still may keep only one")
    stats.companions = len(out)
    return out


# ------------------------------------------------------------------ grouping


def _group(files) -> list[list[File]]:
    """Union by sha256, then by pixel_hash.  Both are exact equality."""
    parent: dict[int, int] = {}
    members: dict[int, File] = {}

    def find(x: int) -> int:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)

    for f in files:
        parent[f.id] = f.id
        members[f.id] = f
    # `stream_hash` is to video what `pixel_hash` is to a photograph: the same
    # recording re-muxed or re-tagged. Certain, and free.
    for key in ("sha256", "pixel_hash", "stream_hash"):
        seen: dict[str, int] = {}
        for f in members.values():
            value = getattr(f, key)
            if not value:
                continue
            if value in seen:
                union(seen[value], f.id)
            else:
                seen[value] = f.id

    groups: dict[int, list[File]] = defaultdict(list)
    for f in members.values():
        groups[find(f.id)].append(f)
    return [sorted(g, key=lambda f: f.id) for g in groups.values()]


# --------------------------------------------------------- canonical choice


def choose_canonical(members: list[File], method: str = "exact") -> tuple[File, str]:
    """PLAN §3.3, highest wins — and source priority is deliberately step 4.

    The real library has 1,671 capture stems holding both a HEIC and a JPEG, so
    ranking by source before format would pick the transcode at scale.
    """
    best_pixels = max(f.pixels for f in members)
    threshold = best_pixels * (1 - PIXEL_TIE)

    if method == "video":
        # A re-encode is smaller and softer; the 1280x720-against-1920x1080
        # pairs in the real library are not interchangeable.
        winner = max(members, key=lambda f: (f.pixels, f.size, f.sha256 or ""))
        others = [f for f in members if f.id != winner.id]
        if others:
            runner = max(others, key=lambda f: (f.pixels, f.size))
            if winner.pixels > runner.pixels:
                why = f"more pixels ({winner.pixels:,} vs {runner.pixels:,})"
            else:
                why = f"larger encode ({winner.size:,} vs {runner.size:,} bytes)"
            return winner, why
        return winner, "only member"

    if method == "burst":
        # §3.2: burst frames share a resolution, so format tier and file size
        # cannot tell them apart and would keep a blurred frame as readily as a
        # sharp one. Resolution still gates the choice — a sharp thumbnail must
        # not beat a full-size frame — but within that band, sharpness decides.
        contenders = [f for f in members if f.pixels >= threshold]
        winner = max(contenders, key=lambda f: (f.sharpness or 0.0, -f.source_priority,
                                                f.sha256 or ""))
        others = [f for f in contenders if f.id != winner.id]
        if others and winner.sharpness:
            runner = max(others, key=lambda f: f.sharpness or 0.0)
            return winner, (f"sharpest frame of the burst "
                            f"({winner.sharpness:.0f} vs {runner.sharpness or 0:.0f})")
        return winner, "sharpest frame of the burst"

    def key(f: File):
        return (
            0 if f.pixels >= threshold else 1,   # 1. pixel count, ties within 2%
            -f.tier,                              # 2. original-ness by format
            -f.size,                              # 3. size at equal dimensions
            f.source_priority,                    # 4. --src order, a tiebreak only
            f.sha256 or "",                       # 5. deterministic
        )

    ranked = sorted(members, key=key)
    winner = ranked[0]
    if len(members) == 1:
        return winner, "only member"
    runner_up = ranked[1]
    if winner.pixels > runner_up.pixels and key(winner)[0] != key(runner_up)[0]:
        why = f"more pixels ({winner.pixels:,} vs {runner_up.pixels:,})"
    elif winner.tier != runner_up.tier:
        why = f"more original format ({winner.mime} over {runner_up.mime})"
    elif winner.size != runner_up.size:
        why = f"larger at equal dimensions ({winner.size:,} vs {runner_up.size:,} bytes)"
    elif winner.source_priority != runner_up.source_priority:
        why = f"source priority ({winner.source} over {runner_up.source})"
    else:
        why = "identical on every criterion; lowest sha256 wins for determinism"
    return winner, why


# ------------------------------------------------------------------ recording


def _record(db, stats, files, members, companion_of, method, evidence=None) -> None:
    canonical, why = choose_canonical(members, method)
    stats.clusters += 1
    stats.bump(stats.by_method, method)

    cursor = db.execute(
        "INSERT INTO cluster (method, confidence) VALUES (?, 1.0)", (method,))
    cluster_id = cursor.lastrowid

    companions = defaultdict(list)
    for video_id, (still_id, rule) in companion_of.items():
        companions[still_id].append((video_id, rule))

    for f in members:
        is_canonical = f.id == canonical.id
        # Inside a burst cluster the copies of the kept frame are duplicates,
        # but a *different* frame is a different photograph. It is collapsed
        # deliberately and recorded as a sibling so `--keep-bursts` can emit it
        # from the catalog later without re-analysing anything (§3.2).
        sibling = (method == "burst" and not is_canonical
                   and f.pixel_hash != canonical.pixel_hash
                   and f.sha256 != canonical.sha256)
        # D9: an edit is not a duplicate. It is the same photograph deliberately
        # changed, so it becomes its own output asset rather than being dropped
        # for looking like its origin. Only 3 files in this library qualify —
        # every one of the 85 `_Original` pairs turned out to be a re-encode,
        # SSIM 0.999 — but silently discarding an edit is the kind of loss that
        # is never noticed, so it is detected rather than assumed absent.
        variant = (not is_canonical and not sibling and f.kind == "image"
                   and f.pixel_hash != canonical.pixel_hash
                   and _is_edit(f))
        role = ("canonical" if is_canonical else
                "variant" if variant else
                "burst_sibling" if sibling else "duplicate")
        db.execute(
            "INSERT INTO member (cluster_id, file_id, role) VALUES (?,?,?)",
            (cluster_id, f.id, role))
        if is_canonical:
            _decide(db, f.id, "canonical", f"kept: {why}")
        elif variant:
            db.execute("UPDATE member SET derived_from = ? WHERE cluster_id = ? "
                       "AND file_id = ?", (canonical.id, cluster_id, f.id))
            _decide(db, f.id, "variant",
                    f"an edited version of {Path(canonical.path).name}; kept as its "
                    f"own asset rather than dropped as a duplicate")
            stats.variants += 1
        elif sibling:
            _decide(db, f.id, "burst_sibling",
                    f"another frame of the same burst as {Path(canonical.path).name}; "
                    f"collapsed by sharpness, recoverable with --keep-bursts")
            stats.burst_siblings += 1
            stats.freed_bytes += f.size
        else:
            _decide(db, f.id, "duplicate",
                    _why_duplicate(f, canonical, method, evidence))
            if f.kind == "video":
                stats.video_duplicates += 1
                stats.video_freed_bytes += f.size
            else:
                stats.duplicates += 1
                stats.freed_bytes += f.size

    # The companion follows the canonical.  If the canonical has none but a
    # sibling does, the pair is still worth keeping — losing the motion half
    # because the better still came from a source that dropped it would be a
    # silent downgrade.
    chosen: tuple[int, str] | None = None
    for f in [canonical, *members]:
        if companions.get(f.id):
            chosen = companions[f.id][0]
            break

    for f in members:
        for video_id, rule in companions.get(f.id, []):
            video = files[video_id]
            adopted = chosen is not None and video_id == chosen[0]
            redundant = (not adopted and chosen is not None
                         and files[chosen[0]].sha256 == video.sha256)
            db.execute(
                "INSERT INTO member (cluster_id, file_id, role, derived_from) "
                "VALUES (?,?,?,?)",
                (cluster_id, video_id, "duplicate" if redundant else "companion",
                 canonical.id))
            if adopted:
                _decide(db, video_id, "companion",
                        f"{rule} companion of {Path(canonical.path).name}")
            elif redundant:
                _decide(db, video_id, "duplicate",
                        f"companion identical to the one kept with "
                        f"{Path(canonical.path).name}")
                stats.video_duplicates += 1
                stats.video_freed_bytes += video.size
            else:
                # Two stills that are the same image but whose movies are not the
                # same bytes.  Probably the same capture, but "probably" is not a
                # licence to delete half a photo.
                _decide(db, video_id, "review",
                        "companion of a duplicate still, but its movie differs "
                        "from the companion being kept")
                stats.review += 1
                stats.bump(stats.by_review_reason, "companion movies differ")


# Apple names an edited copy IMG_E1234.JPG beside the original IMG_1234.JPG.
_APPLE_EDIT = re.compile(r"^IMG_E\d+", re.I)


def _is_edit(f: File) -> bool:
    """Does this filename say it is an edited version of something?

    Naming is the only signal available: an edit is pixel-different from its
    origin but so is a re-encode, and nothing in the pixels distinguishes "the
    user raised the exposure" from "Google re-compressed it".
    """
    name = Path(f.path).name
    if sidecars.edit_origin(name):
        return True
    return bool(_APPLE_EDIT.match(name))


def _why_duplicate(f, canonical, method, evidence) -> str:
    """What this file lost to, in the terms the tier actually used.

    A perceptual member is emphatically *not* pixel-identical to the canonical,
    and saying so in the report would misrepresent the one column a reader uses
    to audit a merge.
    """
    against = f"{Path(canonical.path).name} ({canonical.source})"
    if method == "exact":
        return f"same bytes as {against}"
    if method == "pixel":
        return f"same pixels as {against}"
    if evidence:
        pair = (min(f.id, canonical.id), max(f.id, canonical.id))
        found = evidence.get(pair)
        if found:
            return f"confirmed the same photo as {against} — {found}"
        for (a, b), reason in evidence.items():
            if f.id in (a, b):
                return f"confirmed the same photo, via a sibling — {reason}"
    return f"confirmed the same photo as {against} (perceptual tier)"


def _decide(db, file_id: int, outcome: str, reason: str) -> None:
    db.execute(
        "INSERT INTO decision (file_id, outcome, reason) VALUES (?,?,?)",
        (file_id, outcome, reason))
