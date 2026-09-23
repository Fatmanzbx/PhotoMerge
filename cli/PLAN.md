# PhotoMerge — Design & Build Plan

The *how*. `README.md` is the *what* and the steps you run by hand.

## 0. What the real data actually looks like

Surveyed `Takeout/Google Photos/` on 2026-09-17: **12,610 media files, 12,355 sidecars,
43 GB**, years 2015–2026 plus one album folder.

| Finding | Number | Consequence |
|---|---|---|
| **Sidecar match rate** | **98.0%** | Far better than feared. All 256 "unmatched" are explainable (below) — **zero genuinely orphaned files** |
| **Same-stem, two image formats in one folder** (HEIC + jpeg) | **1,883** | ~15% of the library. The single biggest dedup win, and a pure §3.1-B/C case |
| **Google Motion Photos** (`X.MP` + `X.MP.jpg`) | 150 pairs | A companion format neither doc anticipated — see §3.3 |
| `.mp_original` | 10 | Motion Photo originals, same pairing |
| **Live Photo MP4 companions** (no sidecar, by design) | 80 | Inherit metadata from their still |
| **Extensionless files** | 3 | `IMG_7747`, `IMG_7756`, `IMG_3316` — all actually QuickTime MOV. Extension-based type detection fails outright |
| `-edited` variants (no sidecar) | 13 | Must inherit from origin. Patterns: `-edited`, `~2-edited`, `-EFFECTS-edited`, `original_<uuid>_<name>-edited` |
| `original_<uuid>_` prefixed | 20 | Google's newer edit naming |
| `(1)`/`(2)` collision suffixes | 239 | Sidecar is `NAME.jpg.supplemental-metadata(1).json` — suffix lands on the *sidecar stem*, not the media name |
| Basenames in >1 folder (album vs. year) | 178 | Expected Takeout duplication |
| **Distinct capture stems** | **10,139** | Rough output upper bound from this source alone: ~20% reduction before any cross-source merge |

### The Apple source (`Takeout/apple_export/`)

Surveyed 2026-09-17: **6,363 files, 17.7 GB, one flat folder, no subdirectories.**

| Finding | Number | Consequence |
|---|---|---|
| **All images are `.jpeg`** — zero HEIC | 6,123 | Not an `osxphotos` export. Something transcoded everything to JPEG |
| `.mov` | 240 | Live Photo motion parts, UUID-named |
| **`DateTimeOriginal` present** | **100%** | The feared "Apple Photos edits lost on export" problem does **not** apply to dates |
| GPS present | 69.3% (4,242) | 1,881 photos need location from Google's sidecars |
| `Make` present | 86.9% | Mostly camera originals, not screenshots |
| **Mixed provenance in filenames** | — | Apple `IMG_####` 4,272 · Android `IMG_date_time` 898 · magazine-lockscreen app 308 · **WeChat `mmexport`** 92 · Pixel `PXL_` 76 · bare UUID/MD5 80 |

### Overlap between the two sources

| | |
|---|---|
| Google keys | 10,032 |
| Apple keys | 6,349 |
| **Overlapping** | **6,212 — 98% of Apple is already in Google** |
| Apple-only | 137 |
| Google-only | 3,820 |
| **Union (est. assets)** | **~10,169** |
| Sources on disk | 60.4 GB |
| **Est. merged size** | **37.1 GB** (frees ~23 GB) |

**Source priority inverts.** For **1,646 photos Google holds the HEIC while Apple has
only a transcoded JPEG.** Sampling 50 of those pairs: dimensions identical in 49, with
the HEIC ~70% the byte size — exactly the signature of an original HEIC against a
high-quality JPEG conversion. So a naive `mac > gphotos` priority picks the *worse*
file about 1,600 times. Per-file scoring (pixel count → format tier → MakerNotes) must
outrank source order, and `--src` order must stay a **tiebreak only** (§3.3).

**Filename keys are not identity.** The 50th sampled pair, `IMG_0288`, differs in both
dimensions and aspect ratio — two genuinely different photos sharing a recycled Apple
filename. Every overlap number above is therefore an *estimate from names*; real
identity comes from content hashing. Treat 6,212 as approximate, and never let a
filename match alone justify a merge.

**Space: copy-mode is viable again.** 47 GB free against a 37.1 GB merged output.
Prefer `--copy` for the first run — it keeps the analysis repeatable, which is worth
more than the disk it costs. `--move` (§5b) stays the fallback if space tightens.

**Two plan assumptions were wrong, both in our favour:**

1. **No 51-character truncation in this export.** Filenames run to 101 chars intact. The elaborate truncation-matching worry does not apply here.
2. **GPTH Neo pre-processing is unnecessary.** At 98% exact-match and no orphans, the built-in sidecar reader is sufficient. Neo stays a Phase-2 input option, not a Phase-1 step.

One assumption was confirmed emphatically: **the extension is not the type.** Three files have none at all and are MOV; `.MP` is MP4; `X.MP.jpg` is a still whose stem contains another extension. Type detection must read magic bytes, not filenames.

Still open: whether the iPad is a separate source or already folded into
`apple_export`. Also — `~/Pictures/Photos Library.photoslibrary` still exists, so if
locations were ever set by hand inside Photos.app, `osxphotos` could recover GPS for
some of the 1,881 photos lacking it. Worth checking before `reclaim`.

### What M1 measured (2026-09-17)

`scan` + `extract` over both sources: **18,973 media files, 60.4 GB, zero failures.**
Scan 26 s, extract 8 min at 39 files/s. A rescan of an unchanged library is 0.2 s.

| | | |
|---|---|---|
| **Files with a capture time that is not mtime** | **18,973** | **100%** |
| — from EXIF or QuickTime | 18,220 | 96.0% |
| — **only** from a Takeout sidecar | **753** | 4.0% |
| — mtime only (unreliable) | **0** | 0% |
| UTC offset known | 17,767 | 93.6% |
| GPS | 13,733 | 72.4% |
| Apple `ContentIdentifier` (247 distinct) | 625 | 3.3% |
| Album membership recoverable from folder names | 162 | 0.9% |

**Nothing in this library depends on mtime.** D11's nightmare — a photo filed under
the year it was copied — cannot happen here. The 753 files whose only date is in the
Takeout JSON are the concrete payoff of reading sidecars at all.

**What exact + pixel dedup alone (M2) would do:** 18,973 files collapse to **13,148
groups**, removing **5,825 redundant copies and 16.3 GB**, leaving 44.1 GB. Provable,
no thresholds, no fuzzy matching.

That leaves a gap worth naming: §0 estimates the true union at **~10,169 assets**, so
roughly **3,000 files** are duplicates that byte and pixel identity cannot see —
almost all of them the HEIC-vs-transcoded-JPEG pairs (1,671 capture stems hold both a
HEIC and a JPEG). **Tiers C and D are not a nicety on this library; they are where
the remaining 23% of the reduction lives.**

### What M2 measured (2026-09-17)

Clustering the whole catalog takes 4 s. **18,973 files → 12,901 assets + 247
companions**, every one of them explained in `photomerge_report.csv`.

| | |
|---|---|
| Clusters by exact `sha256` | 12,894 |
| Clusters needing `pixel_hash` | **7** |
| Photo duplicates removable | **5,634 — 11.9 GB** |
| Video duplicates | 191 — 4.4 GB, **flagged only**, never deleted (§5) |
| Companions paired | 248 — motion_photo 160 · content_id 81 · dir_stem 7 |
| Escalated to review | 0 |

The 7 pixel-only clusters are all the same shape: a named file and a hash-named
copy of it differing by ~155 bytes of metadata. Small, but they are exactly what
tier A cannot see, and the tier costs nothing.

**§3.3's criterion ordering is still untested.** What actually decided each of the
5,807 merged clusters: source priority 5,621 · nothing at all (identical on every
criterion) 180 · size at equal dimensions 6 · format tier 0 · pixel count 0. That is
not the ordering failing — it is byte-identical members leaving nothing above step 4
to compare, where picking either file is correct by definition. The case the ordering
exists for, the 1,671 HEIC-vs-JPEG stems, does not cluster until M3. **Assume the
ordering is unvalidated until the perceptual tier lands and re-measure this table
then.**

**D6's cross-source pairing has no work to do here.** All 81 movies paired by
`ContentIdentifier` also sit in the same directory as a same-stem still, so dir+stem
matching would have found every one. Keep the rule — it is how Apple Photos re-pairs
on import (D15), it is more certain than a name coincidence, and the Mac and iPad
sources are not collected yet — but the two rules agreeing 81 times out of 81 is
cross-validation, not a saved library.

### What the Mac re-export changed (2026-09-17)

`osxphotos export --exiftool --touch-file` of `~/Pictures/Photos Library.photoslibrary`
into `Takeout/mac_photos`: **2,631 assets, 6.9 GB, 42 seconds**, and 2,961 skipped as
not downloaded from iCloud. Catalog now **21,604 files → 12,972 assets**.

**It recovered metadata, not photos.**

| | |
|---|---|
| Net new assets from 2,631 new files | **71** |
| Mac copies that won their cluster | 2,508 of 2,631 |
| Clusters where the Mac copy is the **only** member with GPS | **55** |
| Files with a UTC offset | **2,631 of 2,631 (100%)** |
| **HEIC originals recovered** | **0** — the library's local originals are JPEG too |
| Albums / keywords recovered | 0 / 0 — the library has none |
| Photos with adjustments in the library | 9 |

Two expectations did not survive:

1. **No HEIC waiting in the library.** Its locally-held originals are 2,566 JPEG and
   65 MOV. Google remains the only source of HEIC for the 1,671 dual-format stems.
2. **The 409 photos held by no other source are all iCloud-only.** Exporting without
   `--download-missing` recovers exactly zero of them, and that flag needs PhotoKit
   authorisation — a GUI grant, so it cannot be scripted from here.

The export was still worth doing: 55 photos have a location nothing else knew, every
file carries an offset, and it is the authoritative source for anything corrected
inside Photos.app. But **the bulk of what is missing is behind the iCloud download**,
not behind the export.

**Do not delete `apple_export`.** It holds ~2,000 capture stems the library does not,
so it is not a subset despite being a worse copy of what overlaps.

### What M5 measured (2026-09-17)

`resolve` over the 10,008 assets takes **2.4 s**.

| | | |
|---|---|---|
| Assets given a capture time | **10,008** | **100%** |
| Assets given a UTC offset | **10,008** | **100%** |
| — from the file's own offset tag | 9,763 | 97.6% |
| — **from the location** (rank 4) | **1** | 0.01% |
| — **from the nearest dated photo** (rank 4b) | **244** | 2.4% |
| — still unknown | **0** | — |
| Assets given a location | 7,242 | 72.4% |
| Time conflicts | 944 | of which 504 escalated |
| Timezone artifacts resolved | 244 | |
| GPS spreads under 5 km | 1,474 | 5 escalated |
| Claims sitting on batch timestamps, downgraded | 546 | |

**Rank 4b does 244 times the work of rank 4**, which inverts the expectation behind
"use the location". The assets missing an offset are almost exactly the assets missing
GPS — they are the Google-only files whose date comes from a sidecar and which carry no
EXIF at all — so the location can rarely answer for them, while a neighbour in time
nearly always can. Keep rank 4: it is correct, free, and it will matter for a library
whose gaps fall differently. Do not expect it to carry the timezone work.

## 1. Architecture

Six stages over one SQLite catalog, each independently re-runnable and idempotent.
Nothing reaches the output tree until stage 5, which requires `--apply`.

```
mac/ ipad/ gphotos/ ─▶ 1 SCAN ─▶ 2 EXTRACT ─▶ 3 CLUSTER ─▶ 4 RESOLVE ─▶ 5 WRITE ─▶ RESULT/
                          │          │            │           │                    _VIDEOS/
                          └──────────┴────────────┴───────────┴─▶ catalog.sqlite    review/
                                                                       │
                                                                  6 REPORT
```

**The catalog is the product; the output folder is a rendering of it.** That
separation buys re-runnability, `--explain`, the undo manifest, and flipping
`--keep-bursts` without re-hashing 50k files. The current `photomerge.py` does
everything in one in-memory pass, which is why none of those are possible in it.

```sql
file(id, path, source, source_priority, size, mtime, inode, ext, kind,
     sha256, pixel_hash, dhash64, phash256, width, height, sharpness,
     make, model, exposure_key, content_id, status, error)

meta(file_id, field, value, source, confidence)   -- append-only; every claim kept
     -- source: exif | xmp | quicktime | google_json | aae | filename | foldername | fs
sidecar(file_id, kind, path, payload_json)
cluster(id, method, confidence)                   -- exact | pixel | perceptual | burst
member(cluster_id, file_id, role, derived_from)   -- canonical | duplicate | burst_sibling | variant
resolution(cluster_id, field, value, source, confidence, competing_json)
decision(file_id, outcome, target_path, reason, superseded_by)
```

`meta` is append-only. Stage 4 reads and decides; it never mutates. When a resolution
turns out wrong, the evidence for the alternative is still there.

## 2. Scan & extract

**Scan.** Walk sources in priority order. Skip `.DS_Store`, `Thumbs.db`, `._*`,
zero-byte files (recorded as `skipped`, with reason). Cache key
`(path, size, mtime, inode)` — unchanged files skipped on rescan.

**Determine `kind` by magic bytes, never by extension** (§0). Three files in the real
export have no extension and are MOV; `.MP` is MP4.

Sidecar matching is **100.00%** on the real export — 12,610 of 12,610 — with the
cascade as built in M1. Two `(n)` collision conventions coexist in the same export
and both are needed:

    IMG_0088 (1).jpeg   ->  IMG_0088 (1).jpeg.supplemental-metadata.json
    IMG_0899(1).HEIC    ->  IMG_0899.HEIC.supplemental-metadata(1).json

Extension case need not agree either: `IMG_0460(1).MOV` pairs with a sidecar written
against `.mov`, so every lookup goes through a case-folded directory index. The last
two misses were `NAME~2-edited.jpg`, where `~2` marks a second copy and belongs to
the *origin's* filename — the edit inherits from `NAME~2.jpg`, not `NAME.jpg`.
Measured rule mix: exact 12,303 · stem 243 · suffix_n 51 · edited_origin 13.
Still **report the unmatched count as a headline metric** for other people's exports.

The Apple source ships no sidecars at all, so the rate is reported per source; a
single blended number would be meaningless.

**Extract.** One `exiftool -stay_open` process fed batches (`-j -G -n -api QuickTimeUTC`).
Per file: streamed `sha256`; `pixel_hash` = BLAKE2b over the raw RGB buffer **after
applying EXIF orientation**; `dhash64` (fast pre-filter) and `phash256` (verification)
on the orientation-normalised grayscale; **sharpness** = variance of Laplacian (for
burst selection); **exposure key** = `(ExposureTime, FNumber, ISO)`; **`content_id`** =
Apple's `ContentIdentifier`, for cross-source Live Photo pairing. Process pool;
decode-bound, not I/O-bound.

## 3. Clustering

### 3.1 Cascade, most-certain first

**A. Exact** — equal `sha256`. Certain, O(n).

**B. Pixel-identical** — equal `pixel_hash`. Same image, different container or
metadata. Certain, O(n).

**Measured twice, with opposite results — and the second time explains the first.**
The tier's value depends entirely on whether a source *rewrites metadata*, and that is
a property of the export tool, not of the photos:

| Sources in the catalog | Clusters needing tier B |
|---|---|
| Takeout + a plain Apple dump | **7** |
| the same, plus an `osxphotos --exiftool` export | **2,566** — 2,560 of them involving that export |

Two copies straight out of Takeout are *byte*-identical, so tier A already has them and
B adds nothing. An `osxphotos --exiftool` export writes fresh metadata into every file,
so its copies have **identical pixels and different bytes from every other copy in the
library** — invisible to A, certain under B. That is exactly the case §3.1-B was
written for; it just needed a source that produces it.

The corollary matters for Phase 2: **tier B is what makes a re-export cheap.** Without
it, exporting the same library again with better metadata adds thousands of files that
no certain tier can reconcile, and the merge has to guess. Keep B, and expect its yield
to swing wildly with the source mix rather than being a fixed property of a library.

What B still cannot see is *transcoding*: Apple's plain export re-encoded everything to
JPEG, so those pairs differ in pixels and remain tier C's problem.

**C. Perceptual candidates** — **BK-tree over `dhash64`**, not a distance matrix. At
50k files the current `bits[:,None,:] != bits[None,:,:]` allocates ~160 GB and dies.
Produces **candidates only**.

**Built and measured (2026-09-17)** on the real 20,568 dHashes: build **0.03 s, 2.8 MB
peak**, 10,624 distinct hashes. The array v0 would have allocated at this size is
**27.1 GB**. Radius-6 candidate generation takes 8 s. Verified against brute force at
radii 0–64, on uniform hashes and on tight families alike — the pruning is an
optimisation, not a different answer.

**Calibrated against verification, not against raw candidates.** An earlier pass
measured the *unverified* candidate graph and concluded the radius had to be tight: a
naive transitive closure chains 14 assets at radius 2, 67 at radius 4 and **217 at
radius 6**. That measurement was real, but it answered the wrong question — the closure
is never taken over raw candidates. Verifying all 11,758 candidates once and slicing by
distance gives the number that actually governs the default:

| radius | candidates | confirm | burst | review | reject | assets merged | **longest chain** |
|---|---|---|---|---|---|---|---|
| 2 | 7,033 | 6,316 | 276 | 127 | 314 | 2,813 | **6** |
| 3 | 7,758 | 6,510 | 331 | 156 | 761 | 2,901 | **6** |
| **4** | **8,581** | **6,605** | **386** | **183** | **1,407** | **2,945** | **6** |
| 6 | 11,758 | 6,655 | 503 | 202 | 4,398 | 2,983 | **6** |

**The longest chain is 6 at every radius.** Tier D removes the explosion completely,
which is exactly the job it exists to do. The radius is therefore a **recall and compute
dial, not a safety dial**, and the earlier "default to 2" conclusion was wrong in both
directions: it was not buying safety, and it was costing real duplicates — a q95-vs-q40
recompression of one photo sits at dHash distance **3**, and tier D confirms it at SSIM
0.968.

**Default 4.** It reaches 98.7% of radius 6's yield for 73% of the candidates; radius 6
spends 3,177 extra verifications and roughly ten more minutes to find 38 more assets,
tripling the rejects it grinds through to do it.

The review queue stays small throughout — 183 pairs at radius 4 — which is what makes
"escalate rather than guess" affordable as a policy rather than a slogan.
**C2. Geometric escalation** — for pairs narrowly missing C, or whose aspect ratios
differ (a crop), escalate to **ORB keypoints + RANSAC homography** (OpenCV). Asks a
stronger question than "do these look alike": *is there a consistent geometric
transform mapping one into the other?* Confirmed at ≥30 inliers. Robust to crop,
rescale, rotation, colour grading. Runs only on escalated pairs.

**D. Verification** — a candidate is confirmed only if it survives all of:

1. Aspect ratio within tolerance, or a clean crop relationship
2. **Capture fingerprint**: both have EXIF, `DateTimeOriginal` within 2 s, same camera model, same exposure key — decisive when present
3. **Flat-image guard**: low phash bit entropy (sky, wall, blank screenshot) ⇒ require per-tile mean-absolute-error check at common resolution
4. **Structural confirmation** where EXIF is absent: SSIM above threshold
5. **Separation guards**: EXIF-grade timestamps >24 h apart, or GPS >5 km apart ⇒ different photos

Passing C but failing D ⇒ **review queue**, not the bin.

### 3.2 Bursts — collapsed deliberately, never by accident

The current design has no burst concept, and its guards (>24 h, >5 km) never fire on
one — sub-second, same place. So bursts are collapsed *accidentally*, as a side effect
of the threshold. You want them collapsed, but the mechanism matters: identification
must be **positive**, so "collapse a burst" never becomes a licence to merge two
genuinely different photos that happen to look alike.

**Positive burst test** — all of: ≥2 files, phash distance small but pixels **not**
identical; timestamp spread ≤3 s; same camera make/model; same or near-identical
exposure key.

Then `method='burst'`, one `canonical`, the rest `burst_sibling`. **Selection is by
sharpness**, not pixel count — burst frames share a resolution, so the normal quality
score can't discriminate and would keep a blurry frame as readily as a sharp one.

Reported as `burst_collapsed=N`. `--keep-bursts` emits every frame instead, read from
the catalog at stage 5 — **no re-analysis**.

Contrast with a *duplicate*: two files that look alike but are five minutes apart are
not a burst. They're either one capture or two photos, and they take the D path.

### 3.3 Variants, Live Photos, canonical choice

**Variants.** A cluster member that's perceptually matching but pixel-different is an
**edit** when any of: different aspect (crop); Google `-edited` suffix; Apple
`IMG_E####` or adjacent `.AAE`; XMP edit history. `role='variant'`,
`derived_from=<origin>`, becomes its own output asset.

**Measured 2026-09-17: naming is the only usable signal.** Pixels cannot tell an edit
from a re-encode — both are pixel-different from the origin at the same dimensions.
All 85 `_Original` pairs in this library score SSIM 0.989–0.999 against their siblings,
so every one is a re-encode and none is an edit; only 3 files carry edit naming
(`-edited`, `-EFFECTS`). A crop is caught separately by the differing aspect ratio and
goes to review. There are no `.AAE` sidecars in this export at all.

**Live Photos.** Join on `content_id` **first** — that's what makes cross-source
pairing work (Mac's HEIC + iPad's MOV). Fall back to same-directory basename
matching, which is all the current code does and which cannot pair across sources.
The pair moves as one unit; the MOV is never counted as a video. 80 such companions
exist in the Takeout export, plus 3 whose extension was stripped entirely and which
only magic-byte detection will find.

**Google Motion Photos** (150 in the real export, §0). Pairing is *not* stem-equality:
the still is `PXL_….MP.jpg` and the motion file is `PXL_….MP` — the video's full name
is a prefix of the still's. Rule: for each `*.MP` (and `*.mp_original`), the partner is
`<same path>.jpg`. Treat as one asset exactly like a Live Photo; the `.MP` is never
counted as a video and never deduped on its own. On output, strip the stray `.MP` from
the stem so the pair lands as `NAME.jpg` + `NAME.MP` rather than `NAME.MP.jpg`.

**Edited variants carry no sidecar** (13 in the export) and must inherit from their
origin. Recognise `-edited`, `~N-edited`, `-EFFECTS-edited`, and the
`original_<uuid>_<name>-edited.jpg` form, resolving the origin by stripping the
decoration.

**Canonical selection**, highest wins: (1) pixel count, ties within 2%; (2)
original-ness — format tier RAW > HEIC > PNG > JPEG, JPEG quality from quantisation
tables, presence of MakerNotes (a camera original keeps them, a Google re-encode
doesn't); (3) file size at equal dimensions; (4) source priority; (5) lowest `sha256`
as a deterministic tiebreak.

**Source priority is step 4, deliberately** — below format tier. The real data has
1,646 photos where the Google copy is the HEIC original and the Apple copy a JPEG
transcode of it (§0), so ranking by source first would pick the worse file at scale.

The canonical file is chosen for its **pixels**. Its metadata may be worse than a
sibling's — that's the point; stage 4 harvests from the whole cluster.

**Built in M2:** pixel count with the 2% tie band, format tier, size, source
priority, `sha256`. **Deferred to M3:** JPEG quality from quantisation tables and
MakerNotes presence. Both only discriminate between files that are *not* pixel
identical, which by construction cannot happen inside an M2 cluster — they start
earning their keep the moment the perceptual tier lands.

## 4. Metadata resolution

### 4.1 Time — timezone-aware end to end

**This is where the current implementation is wrong.** `photomerge.py:113` converts
Takeout's UTC epoch into *the running machine's* timezone and strips tzinfo; EXIF is
read naive, in the timezone where the shot was taken. For a Tokyo photo on a US-set
Mac those differ by 14 h. When EXIF exists it wins and the result is right by luck;
when EXIF is missing the written time is **wrong by the offset**, and near midnight it
files the photo into the wrong `YEAR/MONTH`. Output also depends on machine locale,
breaking determinism.

**Decided: the zone comes from the location, not from a setting.** Measured against
the real catalog (2026-09-17), which settles the §13 question outright:

| # | Source | Confidence | Measured on this library |
|---|---|---|---|
| 1 | EXIF `DateTimeOriginal` **+ `OffsetTimeOriginal`** | certain | **17,767 — 93.6%** (with 2) |
| 2 | QuickTime `CreationDate` with offset | certain | ↑ |
| 3 | Google `photoTakenTime` (UTC epoch) — **unless** it equals `creationTime`, meaning Google had nothing and used upload time | high | 1,013 rely on it for the *instant* — but it carries **no zone** |
| 4 | EXIF `DateTimeOriginal` localised via **GPS-derived timezone** (`timezonefinder`, offline) | high | **193 — 1.0%** |
| 4b | Zone of the **nearest-in-time photo that knows one**, when the gap is small | medium | would cover **83%** of the 1,013 within 6 h |
| 5 | EXIF `DateTimeOriginal` localised via configured home timezone | medium | **0 files** |
| 6 | XMP `photoshop:DateCreated` | medium | |
| 7 | Filename pattern (`IMG_YYYYMMDD_HHMMSS`, `PXL_…`, `Screenshot_…`, `IMG-YYYYMMDD-WA####`) | low | 0 needed |
| 8 | Folder name encoding a date | low | 0 needed |
| 9 | Filesystem mtime | **flagged** — last resort | **0 needed** |

**Ranks 5 and below have no work to do here.** Every file either carries an explicit
offset, or has GPS, or has a Takeout UTC instant. A configured home timezone can stay
a flag for other people's libraries; it decides nothing on this one.

**Rank 4b is new and earns its place.** The 1,013 files with a Takeout instant but no
zone of their own get a correct *instant* from rank 3, but `DateTimeOriginal` is a
local wall clock by convention, so writing one still needs a zone. No cluster sibling
can supply it — all 1,013 are Google-only files whose clusters contain nothing else.
A nearest-in-time anchor can: the closest photo that knows its zone is **under a
minute away for 54%** of them (the same capture session) and **under 6 hours for
83%**. Only 38 files have no anchor within a day. Inheriting a zone across a
sub-minute gap is far safer than assuming one, and the gap is recorded so a wide
inheritance can be escalated rather than trusted silently.

Never `ctime`. Never let mtime outrank embedded or sidecar data — copying resets it,
and Takeout resets it on every file it writes.

**Conflicts:** within 60 s → agree, take highest confidence. Whole-hour gap of 1–14 h
→ **timezone artifact, not a conflict**; resolve to the offset-bearing source or the
GPS zone, record `tz_resolved`. Same date, different time → flag `soft`. Different
date → **review**.

**Two rules the real data forced, both absent from the table above.**

**1. A capture time can only be wrong *late*.** Copying, re-encoding, restoring from a
backup and re-uploading all push a timestamp forward; nothing pushes it back. So on a
genuine disagreement the **earliest plausible claim wins**, even from a source this
table ranks low — the ranking is a tiebreak *within* an agreeing group, never a licence
to prefer a later time from a better-ranked source. Measured: 944 assets disagree,
504 of them by more than a day.

**2. A timestamp shared by many unrelated assets is not a capture time.** In this
library **1,428 EXIF claims land within four minutes of each other on 2018-12-30**, and
490 QuickTime claims on the day the Apple export ran. A real capture histogram is
nearly flat; a spike is a batch operation stamping files. Any `exif`/`quicktime` claim
on a minute shared by ≥20 distinct assets has its confidence cut to a quarter, which is
what lets the WeChat filename epoch beat a rank-1 EXIF tag that records a phone
restore. 546 claims were downgraded this way.

Together these are why rank 7 (filename) routinely beats rank 1 (EXIF) here. It is not
a reordering of the table; it is the table applying only where the claims agree.

### 4.2 Location

Precedence: EXIF GPS (valid refs) > QuickTime ISO6709 > Google `geoDataExif` (the
camera's own fix) > Google `geoData` (may be hand-typed in the Google UI) > XMP.

**Measured: `geoData` and `geoDataExif` are byte-identical in all 2,280 sidecars here
that carry both.** The distinction costs nothing to keep and matters for other
people's exports, but it decides nothing on this library, and no conclusion should be
drawn from it having "worked".

Reject `(0,0)`, `|lat|>90`, `|lon|>180` — **by explicit null-island test, not
truthiness**; `if lat or lon` also rejects legitimate coordinates on the equator and
prime meridian.

**Borrow `lat`/`lon`/`alt` atomically from one record.** The current per-field loop
can take latitude from one file and longitude from another, producing a coordinate
pointing where neither photo was taken.

Conflicts by haversine: <100 m agree; <5 km take highest precedence, note the spread;
≥5 km → review, **except** EXIF vs. Google `geoData`, where EXIF wins (a hand-dropped
pin shouldn't override a camera's fix).

**Variants** inherit the origin's resolved values unless they carry higher-confidence
ones — an edit exported years later has a misleading timestamp of its own.

### 4.2b Inferring a missing location from its day

Requested 2026-09-17 and built the same day. A photo with no fix takes the location of
the nearest located photo **on the same local date**, but only when every located
photo that day falls inside one city-sized radius (25 km). A day that spans a flight
has no single answer, so it produces none.

| | |
|---|---|
| Assets with no location | 2,766 |
| — on a day with no located photo at all | 1,496 — out of reach |
| — day spans further than one city | 660 — declined |
| — nearest fix too far away in time | 190 — declined |
| **— resolved** | **420** |

Coverage 72.4% → **76.6%**. Chosen radius: measured spreads separate cleanly, with
the rejected days at 3,125 km, 10,755 km and 11,108 km — unmistakably travel.

**The reach depends on the evidence, not on a single threshold.** Several fixes across
a day that all fall in one city *are* evidence the day was stationary, so they can
carry a photo taken between them at any distance in time. One fix is not: "all fixes
within 0 km" is vacuously true of a single point, and an unbudgeted version of this
rule reached 26 hours from a lone anchor. So:

- fixes **bracketing** the photo in time — no time limit (192 inferences)
- fixes all **before or after** it — within 6 h (189)
- a **single** fix — within 3 h (39)

Resulting profile: median gap 0.77 h, 90th percentile 4.1 h, worst 6.0 h; median day
spread 1.4 km, worst 23.0 km.

**This is the only field in the pipeline that is invented rather than harvested**, and
it is treated accordingly: confidence 0.3, the reasoning recorded in
`gps_note`, an inferred fix can never anchor another inference, `--no-infer-location`
turns it off — and the output carries **`EXIF:GPSProcessingMethod = ESTIMATED`**, the
standard field for how a fix was obtained, so no map ever presents a guess as a
measurement.

## 5. Write & report

Requires `--apply`; otherwise prints the plan and stops.

- **Layout** `RESULT/YYYY/MM/`, by the **resolved local** date — one tree holding
  photos, videos and Live Photo pairs together, so a single `osxphotos import` brings
  the whole library in chronologically. (Superseded the earlier `_VIDEOS/` split;
  decided 2026-09-17.) 129 months, the largest holding 956 assets.
- **Copy, never re-encode** — pixels byte-for-byte, only the metadata block rewritten.
  **This survived a direct request to unify formats** (2026-09-17) and the reasoning is
  worth keeping: one codec per type would mean re-encoding 7,355 already-lossy JPEGs to
  HEIC, or 2,007 HEIC originals to JPEG. The second is exactly the damage this project
  exists to undo — Apple's export transcoded everything to JPEG, which is why Google's
  copies are the better source for 1,790 photos (§0). Apple Photos reads HEIC, JPEG,
  PNG, MOV and MP4 natively, so a mixed library costs nothing at import; unification
  would buy tidiness and pay for it in irreversible quality loss on every file.
- **Unified naming and containers, losslessly.** What "unified" is delivered as:
  - extensions normalised — `.jpeg`/`.JPG` → `.jpg`, `.HEIC` → `.heic`, `.MOV` → `.mov`
    (the real export holds 4,327 `.jpg` against 2,998 `.jpeg` for one format)
  - `.MP` and `.mp_original` renamed to the container they **already are** (MP4 and
    QuickTime) — a correction, not a conversion
  - filenames `YYYYMMDD_HHMMSS.ext` from the resolved **local** wall clock, replacing
    ten naming styles (`IMG_####` 5,966 · `PXL_…` 3,137 · `mmexport…` · hash blobs ·
    `original_uuid_…`). Collisions take `_1`, `_2`: measured, 274 stamps collide
    affecting 776 assets, worst case 10 in one second.
  - a Live Photo's two halves share a stem, differing only in extension
  - the original filename is preserved in the manifest and in XMP, because Takeout's
    `title` and Apple's original names are the only trail back to the source
- **Embed** via exiftool argfile batches: `DateTimeOriginal`, `CreateDate`, **`OffsetTimeOriginal`** (currently missing — without it the output perpetuates the ambiguity), GPS lat/lon/alt + refs, Make/Model; QuickTime/Keys equivalents for video. Provenance into XMP so it survives round-trips.
- **Verify** each written file: re-read, confirm `pixel_hash` matches source and tags read back as intended. Mismatch fails the run.
- **Videos**: in the main tree with everything else. Byte-identical duplicates are
  removed like any other exact match — **190 of the 191 video duplicates share a
  `sha256` with the file kept**, which is proof, not a guess. The one that does not
  stays flagged rather than deleted, since nothing verifies video content beyond its
  bytes.
- **Live Photos**: Apple Photos re-pairs on the **`ContentIdentifier`**, not on the filename — the earlier "same stem is enough" note was wrong. Preserve `MakerNotes:ContentIdentifier` on the still and `Keys:ContentIdentifier` on the movie, identical and intact; exiftool will drop MakerNotes on some rewrite paths, so assert the value reads back on both halves. Same stem is still worth keeping, but it is cosmetic.
- **`review/`**: an HTML contact sheet per unresolved cluster — thumbnails side by side, competing values, why it escalated. This is where judgement calls actually get made, so it has to be scannable, not a CSV dump.
- **Undo manifest**: JSON of every copy and write, written **after every batch** rather
  than at the end — in move mode a crash halfway through leaves the sources partly
  renamed, and this is the only record of where anything went. `photomerge undo`
  reverses stage 5 from it, declining any file whose original path is occupied again,
  or whose source has gone (deleting the copy would leave no version at all), and
  clearing `verified_at` so `trash` cannot then stage against a replacement that no
  longer exists.

**Reports.** `photomerge_report.csv` (one row per *input* file; existing columns plus
`role`, `burst_collapsed`, `derived_from`, `tz_resolved`, `review_reason`);
`conflicts.csv`; `report.html` with counts by source, dedup savings, **metadata
coverage before/after**, confidence distribution, review-queue size, unmatched-sidecar
count. Coverage-before/after is the number that answers "did this work".

## 5b. Space, move mode, and deletion

Measured again 2026-09-17 with all three sources catalogued: **29 GB free**, sources
**72.2 GB**, output **42.3 GB**, reclaimable **29.9 GB**. Copy mode needs 42.3 GB free
alongside the sources and therefore **cannot run** — `--move` is the mode, not the
fallback. (§0 briefly thought copy mode was viable again at 47 GB free against a
37.1 GB estimate; the Mac re-export and the iCloud downloads spent that margin, and
the real output is 42.3 GB.)

**Safety invariant, enforced in the catalog — built 2026-09-17.** `decision` carries
`verified_at`, stamped by stage 5 only after it re-read the written file and confirmed
both that its decoded pixels hash to the source's and that the tags read back. Every
dropped file's `superseded_by` points at the decision that replaces it, and `trash`
refuses to stage — and `reclaim` to unlink — anything whose replacement lacks
`verified_at`. So "delete the duplicate" is structurally dependent on "the replacement
is provably good" rather than on the order the stages ran in. Verified by test: with
`--no-verify`, staging moves nothing at all.

**Three modes:**

| Mode | Behaviour | Peak extra space |
|---|---|---|
| `--copy` | Canonical copied; sources untouched | size of output |
| `--move` *(required here)* | Canonical renamed into place; superseded files renamed into `.trash/` | one file + catalog |
| `reclaim --confirm` | Unlinks `.trash/`; separate, explicit, irreversible | frees space |

`photomerge restore --out RESULT --apply` puts `.trash/` back, from a ledger written as
staging happens. A review window that cannot be acted on is not a review window.

Same-volume rename is atomic and free, so both the move and the `.trash/` staging cost
nothing. `.trash/` buys a review window without buying it with disk.

**Cost of move mode, stated plainly:** the analysis becomes non-repeatable. Once the
superseded copies are unlinked, re-clustering at a different threshold is impossible —
the evidence is gone. The catalog survives (so `--explain`, the manifest and the
provenance report still work), but the pixels do not. Dry-run and contact-sheet review
are therefore mandatory *before* the first `--move`, not after.

**Rounds.** All sources cannot coexist on disk. `RESULT/` is itself a source on the
next round, and the catalog persists, so: Google → `RESULT/`; then Mac exported in
year batches, each merged and deleted before the next; then iPad. Requires the runner
to be idempotent against an existing output tree — a file already present and verified
is a no-op, not a re-copy.

**Pre-flight.** Before any `--apply`, estimate output size from the catalog and refuse
to start if free space is below (largest file × parallelism) + catalog + margin.

## 5c. Apple Photos as the import target

The output is graded on whether Photos ingests it cleanly, which constrains several
choices:

- **Embed, never sidecar.** Photos ignores `.xmp` on import. Already decided (§5); this is the reason.
- **`ContentIdentifier` is the Live Photo pairing key** (§5). Verify it survives the metadata rewrite on both halves.
- **Photos does not understand Google Motion Photos.** Default: import the `.MP.jpg` still, keep the `.MP` beside it, unimported. Optional `--motion-to-live` writes a shared `ContentIdentifier` plus the `com.apple.quicktime.still-image-time` marker to convert the pair into a real Live Photo — genuinely possible with exiftool, but mark it experimental and verify on a sample before running it over 150 files.
- **Folder structure does not become albums.** `RESULT/YYYY/MM/` is for humans; Photos flattens it. An album folder survives only if passed explicitly at import.
- **Import with `osxphotos import --walk --skip-dups --report`**, not drag-and-drop: it reports per-file outcomes, which is what makes the import auditable in the same way the merge is.
- **Timestamps**: Photos reads `DateTimeOriginal` and `OffsetTimeOriginal`. Writing the offset (D8) is what stops photos taken abroad landing at the wrong local time in the Photos timeline.

## 5d. Landing in Apple Photos on this Mac

The destination is a Photos library on this machine, not a folder. Photos **copies**
files into its library, so the naive path — sources 60.4 GB + `RESULT/` 37.1 GB +
library 37.1 GB = **134.6 GB against 47 GB free** — cannot run. Order of operations
is therefore part of the design.

### Sequence

| Step | Action | Free space after |
|---|---|---|
| 1 | **Analyze** both sources → catalog (~100 MB). Read-only. | 47 GB |
| 2 | **Review and tune here** — contact sheets, thresholds, conflicts. Fully repeatable while sources are intact. | 47 GB |
| 3 | **Materialize `--move`** — sources shrink as `RESULT/` grows | ~70 GB |
| 4 | **Import** into a new Photos library (managed) | ~33 GB |
| 5 | **Verify** import report against the manifest | ~33 GB |
| 6 | **Delete `RESULT/`** (only what the report confirms imported) | ~70 GB |
| 7 | Delete the old Photos library once satisfied | +its size |

**`--move` is required again, and step 2 is why that is acceptable.** Copy-mode would
leave 9.9 GB free before the import even begins. All re-clustering and threshold work
happens at step 2 while every source file is still present; the move is a single
irreversible commit made *after* the decisions are reviewed, not before.

### Constraints the target imposes

- **New library, not the existing one.** The existing library and `apple_export` differ by <5%, so the library is effectively the Apple source; importing the merged set into it re-adds ~6,000 photos. Option-launch Photos → *Create New Library*. A new library also makes verification trivial: the count should equal the manifest's canonical count (~10,169).
- **Managed, not referenced.** Do **not** uncheck "Copy items to the Photos library". `RESULT/` is deleted at step 6, and a referenced library would break with it.
- **`osxphotos import`, not drag-and-drop** — it sets albums, skips duplicates and emits a per-file report, which is what makes step 5 possible. Requires Full Disk Access for Terminal (System Settings → Privacy & Security).
- **Never delete what Photos did not import.** Step 6 reconciles the import report against the manifest; anything unimported moves to a folder that survives cleanup. Without this, formats Photos rejects vanish silently.
- **iCloud Photos**, if enabled afterwards, needs a plan covering ~37 GB.

### Motion Photo → Live Photo conversion

Apple Photos cannot read Google Motion Photos, so the `.MP` pairs are converted
rather than archived. **Built and validated on 5 real pairs 2026-09-17** — and both
halves of the recipe as written above were wrong.

**1. `ffmpeg -i NAME.MP -c copy` loses the motion.** A Motion Photo holds four
streams: the clip (1440×1080, 54 frames), a *second* single-frame video stream that is
the still at 2048×1536, and two data tracks. ffmpeg selects by resolution, so the plain
copy keeps the **still** — 3,695,971 bytes in, **197,996 bytes out**, the motion gone
and nothing to indicate it. `-map 0:v:0 -c copy -f mov` takes the clip; still a stream
copy, nothing re-encoded. A size guard refuses any remux that keeps under half the
source, because replacing a clip with one frame of it is worse than leaving it alone.

**2. exiftool cannot write the identifier at all.** Not "might not satisfy Photos" —
it will not create an Apple MakerNotes block that is not already there, and it reports
`1 image files unchanged` while doing nothing. Measured: `-MakerNotes:ContentIdentifier`,
`-Apple:ContentIdentifier`, `-XMP:ContentIdentifier`, `-XMP-apple-fi:ContentIdentifier`
and `-QuickTime:ContentIdentifier` all fail on a JPEG.

**The pairing is therefore delegated to `makelive`** (an osxphotos dependency, already
installed), which writes the Apple MakerNotes identifier on the still and the `Keys`
atom on the movie, and offers `is_live_photo_pair` as a real read-back check. This is
§10's "delegate the volatile surface" applied to Apple's format instead of Google's.
`osxphotos import --auto-live` does the same thing at import time and is the fallback.

Validated on 5 real `.MP` pairs: **remuxed 5, paired 5**, motion preserved at
1440×1080 with 35–65 frames, file sizes unchanged but for container overhead, and
`is_live_photo_pair` true for all five. The 10 `.mp_original` files need nothing —
they are already Apple movies carrying their identifier.

**Visual acceptance passed 2026-09-17.** Seven pairs were imported into Photos — the
5 converted Motion Photos plus 2 untouched Apple Live Photos as a control — and all
seven showed the Live Photo badge, played on press, and arrived as single items with
the right date, offset and map pin. The conversion is confirmed end to end, not just
at the metadata level. All 160 can run.

## 6. No machine learning

Everything above is classical: cryptographic and perceptual hashing, DCT signatures,
Hamming distance, keypoint geometry, SSIM, Laplacian variance. No model, no weights.

Not austerity — a learned embedding is the **wrong shape** here. CLIP/DINOv2 encode
*semantic* similarity ("a beach at sunset"), but the question is "is this the same
shutter press." Burst frames sit on top of each other in embedding space, and so do
two different photos of the same wall — which makes the §3.2 design (collapse bursts
positively, keep distinct photos apart) impossible to express. Classical also stays
auditable ("Hamming 6/256, 47 RANSAC inliers, exposure key matched" is checkable;
cosine 0.94 is not) and deterministic across machines. Near-duplicate detection was
solved before deep learning, and classical methods are better at it.

If the survey surfaces a category where they measurably fail against the fixtures,
reconsider then — with a number.

**Dependencies, all free/OSS:** exiftool (GPL/Artistic), Pillow (MIT-CMU), pillow-heif
(Apache-2.0), rawpy (MIT), OpenCV (Apache-2.0 — ORB is patent-free by design, avoid
SURF), numpy (BSD), timezonefinder (MIT, offline), scikit-image (BSD), ffmpeg
(LGPL/GPL), SQLite (public domain). Nothing paid, rate-limited, or network-dependent.

## 7. Defects in the v0 script to fix

The script is now `.archive/photomerge_v0.py`; line numbers below refer to it there.
**Status** is what M1 changed.

| # | Where | Defect | Status |
|---|---|---|---|
| D1 | `:237` | N² distance matrix — ~160 GB at 50k files. Replace with BK-tree. | **closed** — `photomerge/bktree.py`: 2.8 MB and 0.03 s on 20,568 hashes, verified identical to brute force at radii 0–64 |
| D2 | `:113` | Takeout UTC converted to *machine* timezone then made naive. Machine-dependent output; wrong times when EXIF absent. | **closed** — exiftool runs with `TZ=UTC`, claims are stored as UTC instants or as an explicit local-plus-offset pair, and `test_pipeline.py` asserts an identical catalog under Tokyo, Chicago and UTC |
| D3 | `:270` | `lat`/`lon` borrowed independently — can assemble a coordinate from two different files. | **closed** — GPS is one atomic `gps` claim read from `Composite:`; a lat-only record yields nothing |
| D4 | `:174` | dHash computed without EXIF orientation normalisation — rotated-by-tag vs. rotated-in-pixels copies never cluster. | **closed** — every hash runs after `exif_transpose`; tag-rotated and pixel-rotated copies now hash identically |
| D5 | `:120` | `if lat or lon` rejects legitimate equator/prime-meridian coordinates. | **closed** — only the exact `(0,0)` sentinel is rejected; equator and prime-meridian fixes survive |
| D6 | `:154` | Live Photo pairing keyed on `(parent_dir, stem)` — cannot pair across sources. Needs `ContentIdentifier`. | **closed** — paired in stage 3 on `content_id` first, falling back to dir+stem. Measured: 81 movies pair on `content_id`, and dir+stem finds the same 81, so the rule is currently cross-validation rather than reach (§0) |
| D7 | `:245` | Separation guards never fire on bursts; collapse happens by accident, not by positive identification. | open — M4 |
| D8 | `:311` | No `OffsetTimeOriginal` written — output perpetuates timezone ambiguity. | **closed** — `OffsetTimeOriginal`, `OffsetTime` and `OffsetTimeDigitized` are written for every photo, `Keys:CreationDate` with its offset for every video, and both are re-read and confirmed |
| D9 | — | No variant concept; an edit is silently dropped as a duplicate. | **closed** — a member whose name says it is an edit and whose pixels differ from the canonical takes `role='variant'`, `derived_from` its origin, and is written beside it as `NAME_edited.ext` rather than counted as removable. Measured: only 3 files qualify here, because **all 85 `_Original` pairs are re-encodes** at SSIM 0.989–0.999, not edits — but naming is the only signal that distinguishes the two, so it is checked rather than assumed |
| D10 | — | No review queue; every cluster auto-decided, no escalation path. | started — `decision.outcome='review'` exists and is used when two duplicate stills have different movies; contact sheets are M7 |
| D11 | `:205` | mtime silently fills `dt` and then determines the output folder. Should be flagged and escalated. | **closed** — mtime is a separate `fs` claim at confidence 0.05 and is excluded from conflict detection entirely unless it is the only evidence; left in the pool it disagreed with every real capture time by years and marked the whole library as conflicted. Measured: 0 assets depend on it |
| D12 | — | EXIF read via Pillow misses HEIC/MOV tags and MakerNotes. Read through exiftool. | **closed** — all reads go through one `exiftool -stay_open` process |
| D13 | `:36` | `IMG_EXT`/`VID_EXT` classify by extension. The real export has 3 extensionless MOVs, and `.MP`/`.mp_original` are in neither set — 163 files silently ignored. Detect by magic bytes. | **closed** — `kind` comes from magic bytes. All 163 files v0's extension sets ignored are now typed: 3 extensionless → QuickTime, 150 `.MP` → MP4, 10 `.mp_original` → **QuickTime, not MP4** |
| D15 | `:311` | Metadata rewrite does not preserve `ContentIdentifier`; Live Photo pairs will not re-pair in Apple Photos regardless of filename. | open — M6 |
| D16 | — | No `--move`/`reclaim`; copy-only cannot run in 28 GB of free space. | **closed** — `write --move`, `trash`, `restore`, `reclaim --confirm`, and a pre-flight check that refuses a run which cannot fit |
| D14 | `:154` | No Motion Photo pairing. `X.MP` + `X.MP.jpg` is a prefix relationship, not stem equality — 150 pairs in the real export would be split. | **closed** — the prefix rule pairs all 160 `.MP`/`.mp_original` files with their stills; conversion to Live Photos is still M6c |

**Verified good, keep as-is:** the sidecar-matching cascade, exiftool argfile batching,
the DSU clustering structure, the video preservation design, the report column set,
and the overall stage decomposition.

## 8. Tests

The synthetic fixture generator is the foundation and ships with the suite — it means
anyone can contribute a failing test without shipping their actual photos.
Deterministically construct: high-res original with full EXIF + GPS; byte-identical
copy in another source; recompressed (q95 vs q60); downscaled + EXIF-stripped +
Takeout sidecar; **rotated by EXIF tag vs. baked into pixels** (D4); **crops at
10%/30%** (C2); **burst sequences** (positively identified, collapsed by sharpness);
**flat images** — sky, white wall, two screenshots differing in one digit (must stay
apart); Live Photo pair **split across two sources** (D6); **Takeout JSON in a
shooting timezone far from the test machine's** (D2 — assert identical output under
`TZ=Asia/Tokyo` and `TZ=America/Chicago`); `(0,0)`, equator and prime-meridian GPS
(D5); lat-only record (D3); videos byte-identical across sources plus a recompressed
variant.

Precision/recall per tier reported on every threshold change. **False merges are the
hard failure** — a missed duplicate costs disk, a false merge loses a photo forever.
Two standing properties: *no input photo is unrepresented in the output* (modulo
intended dedup/burst collapse), and *no output has metadata worse than the best input
in its cluster*.

## 9. Milestones

| M | Deliverable |
|---|---|
| **M0** ✅ | **Survey tool.** Counts by format, EXIF coverage, sidecar match rate, duplicate and burst estimates, oddities. Run **first** — checks this plan's assumptions against the real data before anything is built on them. |
| **M1** ✅ | Catalog + scan + extract, with resume. exiftool-based reads (D12). **Done 2026-09-17** — `photomerge scan|extract|status`, 45 tests, run clean over the whole 18,973-file library (§0). Closed D2, D3, D4, D5, D12, D13; D11 mostly. |
| **M2** ✅ | Exact + pixel clustering, manifest, dry-run report. **Provably safe, likely removes most duplicates on its own.** **Done 2026-09-17** — `photomerge cluster|report`, 67 tests, 18,973 files → 12,901 assets, 11.9 GB removable (§0). Closed D6, D14. "Removes most duplicates" held — 5,825 of the ~8,800 redundant files, 66% — but it is tier **A** that does it, not tier B as §3.1-B predicted. |
| **M3** | ~~Fixture suite~~ (built in M1–M2: `tests/fixtures.py`, 67 tests), then BK-tree perceptual tier + verification cascade + C2 (D1, D4). **This is where the remaining ~3,000 duplicates are** (§0). |
| **M4** | Burst identification and sharpness-based collapse (D7). |
| **M5** ✅ | Metadata resolution: timezone-aware, atomic GPS, conflicts (D2, D3, D5, D8, D11). **Done 2026-09-17** — `photomerge resolve`, 109 tests, every asset given a date *and* a zone (§0). Added two rules the plan lacked: earliest-wins and batch-timestamp downgrading (§4.1). D8 remains open — it is the write side. |
| **M6** | Write + embed + verify; variants (D9); cross-source Live Photo pairing (D6); `ContentIdentifier` preservation (D15). |
| **M6b** ✅ | `--move`, `.trash/`, `reclaim --confirm`, pre-flight space check, idempotent re-run against an existing `RESULT/` (D16). **Gates the first real run.** **Done 2026-09-17** — plus `restore`, and the `verified_at` invariant enforced in the catalog. Closed D16. |
| **M6c** ✅ | Motion Photo → Live Photo conversion (§5d), validated on a 5-pair sample first. **Done 2026-09-17** — `photomerge livephotos`, 141 tests. Both steps of the planned recipe were wrong and are documented in §5d. Visual acceptance passed on 5 converted pairs against an Apple control. |
| **M8b** | `osxphotos import` into a new library, import-report reconciliation against the manifest, then staged cleanup (§5d steps 4–7). |
| **M7** ✅ | Review queue contact sheets, `report.html`, undo manifest, `--explain`. **Done 2026-09-18** — `photomerge review|explain|undo`, `report.html` written by `report`, 155 tests. `explain` answers from the catalog alone, so it keeps working after `reclaim` has removed the evidence it describes. |
| **M8** | Real-library run, verification checklist, edge-case log. |

M0 → M2 is the first genuinely useful checkpoint: a safe, provable dedup with a full
manifest, before anything fuzzy is switched on. M1's numbers size it exactly: M2
removes 5,825 files and 16.3 GB with certainty, and leaves ~3,000 duplicates that
only M3 can see (§0).

**Risks.** False merge loses a photo → verification cascade, positive burst
identification, flat-image guard, nothing deleted, contact sheets. Burst collapse
discards a wanted frame → positive identification only, reported, `--keep-bursts`
reverses from the catalog. Sidecar naming defeats matching → cascade + unmatched count
as a headline metric. Timezone errors shift dates across a day boundary → aware
datetimes, whole-hour rule, cross-TZ determinism test. Apple Photos edits lost at
export → `osxphotos --exiftool`, an acquisition-stage failure no downstream code can
repair. HEIC/RAW decode gaps → degrade to hash-only clustering and flag, never
silently drop.

## 10. Phase 2 — open source

Gated on Phase 1 (§12). Phase 2 being a real goal is why the catalog, resume,
`--explain`, undo manifest and fixtures are built in Phase 1 rather than bolted on.

**Positioning.** The README's first paragraph writes itself:

> A photo's best-pixels copy and its best-metadata copy are frequently not the same
> file. Existing tools pick one file and discard the rest — along with whatever
> location and date only the discarded copies knew. PhotoMerge merges N sources into
> one library, keeping the best pixels and the union of the metadata.

**The gap.** GooglePhotosTakeoutHelper (5.5k stars, stale since Jan 2025) and its
maintained **Neo** fork do Takeout → chronological folders. PhotoSweeper X (~$18) and
dupeGuru/Czkawka do single-machine dedup, the latter not metadata-aware. Apple Photos
dedups within one library. Mylio ($240/yr) consolidates devices but skips videos and
ignores Takeout JSON. immich is a server, not a migration tool. **Every one is
single-source or single-machine.** Nothing does "N heterogeneous sources → one
canonical library with metadata union."

**Do not write another Takeout parser.** It's the dirtiest part of the problem, breaks
whenever Google changes the format, and Neo already maintains one. Rebuilding it means
an endless chase for zero differentiation — precisely what buried the original GPTH.
Accept a Neo output directory as a first-class source; keep the built-in sidecar
reader as a fallback. **Scope discipline is the main risk control in this project.**

**Roadmap.** v0.1 "works for me" — Phase 1 cleaned up, single CLI, `pip install -e .`.
v0.2 "works for other people's messes" — Neo as a declared source type, `verify`
subcommand, edge cases from the log each with a regression fixture, real HEIC
coverage. v0.3 "trustworthy" — undo manifest, `--explain <file>`, configurable
keep-policy. v1.0 — docs with real screenshots, Homebrew formula or single binary
(the audience is substantially non-technical; `pip install` loses most of them).

## 11. Maintenance boundary

GPTH didn't fail technically — it was buried under unpaid support load. Decided up front:

- **Position as a one-shot migration tool**, not a library manager. A migration tool is allowed to be *finished*; a photo manager never is.
- **Delegate the volatile surface** (Takeout format) to Neo.
- **Issue template requires a reproducible fixture.** "It didn't work on my 200 GB library" is not actionable and gets closed as such, without guilt.
- **Write the "not planned" list into the README on day one**, so saying no later is citing policy rather than picking a fight.

`photomerge` is taken in several ecosystems — check PyPI and GitHub before committing
to the name.

## 12. Decision gate

Do not start Phase 2 until: Phase 1 ran end-to-end on the real library; the output is
trusted enough to delete the source copies; the edge-case log has ≥5 genuinely
surprising entries; and you still want to maintain this in three months.

**Status 2026-09-18.** Ran end-to-end ✅ — 22,940 files → 10,017 items in Photos, every
file accounted for. Sources deleted ✅ — 29.9 GB reclaimed after verification. Edge-case
log ✅ — 14 entries in [`BUILDLOG.md`](../docs/BUILDLOG.md). **The fourth condition is
unanswered and should stay that way for now**; it is the one that decides whether this
becomes a repo or a gist, and three of four is not a reason to rush it.

If the last is false, publish the script as a gist with a good README and stop. A
documented dead end in a category full of abandoned repos is worth more than another
abandoned repo.

## 13. Open

- ~~**Mac source**~~ — **answered 2026-09-17: `Takeout/apple_export` is the Mac's
  Photos library, at most 5% different from it.** That makes it a *lossy re-export of
  a library still sitting on this Mac* (22 GB at `~/Pictures/Photos Library.photoslibrary`):
  one flat folder, 6,123 JPEG, **zero HEIC**, zero `.AAE`. Re-exporting with
  `osxphotos export --exiftool --download-missing` is a strict upgrade of the same
  photos — it recovers HEIC originals and, more importantly, any date or location
  corrected by hand inside Photos.app, which lives in the Photos database and is
  **unrecoverable downstream** once omitted (README §1). Do this before M8.
- **iPad** — still unknown: a separate source, or already inside the Mac library.
- ~~**The iCloud-only assets**~~ — **answered 2026-09-17: settled, and the gap is not
  ours to close.** "Download Originals to this Mac" pulled every asset the account
  owns; what remained stopped dead at 1,106, of which **1,105 are iCloud *shared
  album* photos** — a setting boundary, not a failure.

  All 408 photos held by no other source belong to a single shared album, and
  `cloud_owner_hashed_id` splits them by contributor: every photo the library's owner
  contributed is already in the library at full resolution, and the gap is entirely
  other contributors' photos, served by iCloud at ~3 MP
  (2049×1537) against our own 12 MP — the originals live in their accounts, and no
  permission grant reaches them.

  **Decision: skip them.** Shared Albums are an iCloud construct that syncs to any
  library signed into the account, so they reappear after the migration without being
  exported; they are not ours; and the copies available are quarter-resolution. The
  one real risk is the album's owner deleting it, which would end access — if that
  album ever matters more than that risk implies, export with
  `osxphotos export … --shared --download-missing --use-photokit` as a **separate
  source**, so 3 MP files can never outrank a full-resolution copy in canonical
  selection and can be dropped later without unpicking the merge.
- **Source priority** — presumably `mac > ipad > gphotos`, but M1 reinforces §0's warning: 1,671 capture stems hold both a HEIC and a JPEG, so per-file scoring must outrank source order and `--src` must stay a tiebreak only.
- ~~**Home timezone**~~ — **answered 2026-09-17: the zone comes from the location.**
  Measured: 93.6% carry an explicit offset, 1.0% resolve from GPS, and the remaining
  5.3% have a Takeout UTC instant. **Zero files need a configured home timezone.** It
  stays a flag for other people's libraries only. See §4.1, including the new rank 4b
  that covers the 1,013 files holding an instant but no zone.
- ~~**Code language**~~ — **settled 2026-09-17: English throughout** (code, comments, CLI, docs), since §10 targets an open-source Phase 2 and a later translation pass would touch every line twice.
- **Near-duplicate screenshots and app-made images** — measured, and it is a sizing
  answer rather than a yes/no. **2,067 images (10.9%) carry no camera `Make`**, of
  which 2,066 also have no GPS; 808 of them share one phone-screen resolution
  (1440×2560), the magazine-lockscreen app accounts for 913, and only 42 are literally
  named `Screenshot*`. For all of these, tier D's **capture fingerprint is
  unavailable** — no camera model, no exposure key, often no EXIF time — so they fall
  through to the structural path and the flat-image guard alone. **That is the
  population where M3 is most likely to merge two photos that are not the same
  photo**, and it is a tenth of the library. Size the fixture suite accordingly.
