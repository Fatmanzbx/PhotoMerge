# PhotoMerge — Requirements

Merged spec. Supersedes the requirements halves of `PLAN.md` and `PHOTOMERGE_PLAN.md`.

## 1. Goal

Consolidate photos scattered across **a Mac, an iPad, and Google Photos** into one
deduplicated library, organised `YEAR/MONTH/`, in which:

- every photo that exists in any source appears exactly once,
- each surviving file is the highest-quality copy available,
- each surviving file carries the best capture time and GPS available **from any copy**,
- every video is preserved, unmerged, for manual sorting,
- no original is deleted — ever, by the tool.

**Phase 1** is a personal migration: get one real library right, once.
**Phase 2** is an open-source tool. Phase 2 is a stated goal, so Phase 1 is built
with it in mind — but Phase 1 correctness gates Phase 2 (§10).

## 2. The core insight

> A photo's best-pixels copy and its best-metadata copy are frequently **not the same file**.

The Mac original is full resolution but may have no GPS. The Google copy is
downscaled and re-encoded, but its JSON sidecar knows the shot was taken in Tokyo
on 2020-08-11. Any tool that keeps the best file and deletes the rest throws that
location away permanently.

So the pipeline is: **cluster by content → pick best pixels → union the metadata
across the whole cluster → write it back.**

This is the entire differentiator, and everything else is implementation.

## 3. Why this is harder than dedup

**3.1 The same photo is not the same file.** Google's storage-saver re-encodes;
Apple exports HEIC; a photo that went through a chat app came back at 1024px.
Byte-different, often pixel-different, all one capture.

**3.2 Sources contradict each other.** EXIF `DateTimeOriginal` carries no timezone.
Google's `photoTakenTime` is a UTC epoch. They disagree by exactly the UTC offset,
which *looks* like a conflict and is not. Filesystem mtime is almost always the copy
time and is actively misleading. Google's `geoData` may have been typed in by hand
years later and disagree with the camera's own fix.

**3.3 Near-identical is not identical.** Bursts, a blank wall, a sky, two screenshots
differing in one digit — all defeat perceptual hashing. Over-merging silently
destroys photos and the user cannot audit what vanished.

**3.4 Metadata you already fixed lives outside the files.** Dates and locations
corrected inside Apple Photos live in the Photos database, not in the image files.
A naive export drops them silently. This is an acquisition-stage requirement
(§RUNBOOK 1a), and missing it loses work already done by hand.

## 4. Definitions

| Term | Meaning |
|---|---|
| **File** | One file on disk in a source. |
| **Asset** | One capture as a unit. A Live Photo is one asset of two files (image + MOV). |
| **Cluster** | A set of files believed to be the same photograph. |
| **Canonical** | The one file in a cluster carried to the output. |
| **Duplicate** | Same capture, different file. Dropped (copy not made), recorded. |
| **Burst sibling** | *Different* capture, same moment. Deliberately collapsed (§6.2). |
| **Variant** | A derivative — edit, crop, markup. Kept as its own asset, linked to its origin. |
| **Provenance** | Per-field record of where each final metadata value came from. User-facing. |

## 5. Inputs

Assume all of the following, because real exports contain all of it:

- **Formats:** JPEG, HEIC/HEIF, PNG, GIF, WebP, TIFF, RAW (CR2/NEF/ARW/DNG), MP4, MOV, Live Photo pairs.
- **Sidecars:** Google Takeout `<name>.<ext>.json` and `.supplemental-metadata.json` — truncated at 46/51 chars, with `(1)` collision suffixes landing on the stem or the extension inconsistently. Apple `.AAE`. `.XMP`.
- **Metadata states:** full EXIF; EXIF stripped; EXIF present but wrong; GPS present; GPS `(0,0)`; timestamps with and without UTC offset.
- **Filenames:** `IMG_1234`, `IMG_E1234` (Apple edited), `PXL_20230405_123456789`, `Screenshot_…`, `IMG-20230405-WA0001` (WhatsApp, date only), `<name>-edited.jpg` (Google), `<name>(1).jpg`.
- **Structure:** arbitrary nesting; the same photo in both an album folder and `Photos from 2019/` (normal for Takeout); corrupt and zero-byte files.
- **Scale:** 10k–50k files across three sources.

## 6. Functional requirements

### Clustering
- **FR-1** Detect byte-identical files.
- **FR-2** Detect pixel-identical files whose containers or metadata differ (EXIF stripped, re-wrapped, orientation applied vs. baked in). This tier does most of the real work.
- **FR-3** Detect perceptually matching files differing in resolution or compression, treating the resemblance as a **candidate** requiring independent verification before it is acted on.
- **FR-3a** Normalise EXIF orientation before computing any perceptual hash. Apple and Google disagree on rotation handling, so an un-normalised hash misses real duplicates.
- **FR-4** Detect duplicates surviving heavy crop, rescale, or colour grading, by geometric verification rather than appearance similarity alone.
- **FR-5** Do not cluster visually flat images (sky, wall, blank screenshot) on perceptual similarity alone.
- **FR-6** Recognise an edit/crop/markup as a **variant**: keep it as its own output asset, record `derived_from`, and inherit the origin's resolved metadata unless the variant carries better of its own.
- **FR-7** Pair Live Photo stills with motion files, **including pairs split across sources** (Mac has the HEIC, iPad has the MOV). Basename matching alone cannot do this; use Apple's `ContentIdentifier`.

### Bursts
- **FR-8** Identify a burst **positively** — sub-3-second spread, same camera make/model, near-identical exposure settings — rather than letting the perceptual threshold swallow it by accident.
- **FR-9** Collapse each burst to one frame, selected by **sharpness** (variance of Laplacian), not by pixel count — burst frames share a resolution, so the usual quality score cannot discriminate.
- **FR-10** Report every collapse (`burst_collapsed=N`), and make it reversible via `--keep-bursts` **without re-running the analysis**.

### Canonical selection
- **FR-11** Within a cluster, choose the file with the most real image information: pixel count, then evidence of being an original rather than a re-encode (format tier, JPEG quantisation quality, presence of MakerNotes), then file size at equal dimensions, then declared source priority.
- **FR-12** Selection must be deterministic — same inputs, same choice, every run, on any machine.

### Metadata resolution
- **FR-13** Harvest candidates from **every** file in the cluster and its sidecars, not only from the canonical file.
- **FR-14** Resolve conflicts by documented precedence (PLAN §5), recording for each field the winning source, the competing values, and a confidence.
- **FR-15** Treat all times as timezone-aware internally. Recognise the whole-hour disagreement between an offset-less EXIF timestamp and a UTC epoch as a **timezone artifact, not a conflict**, and resolve it using the GPS-derived timezone.
- **FR-16** Borrow `lat`/`lon`/`alt` as an **atomic unit** from a single source record. Never assemble a coordinate field-by-field from different files.
- **FR-17** Reject bogus locations (`0,0`, out-of-range) rather than propagating them, without rejecting legitimate coordinates on the equator or prime meridian.
- **FR-18** Never let filesystem mtime outrank embedded or sidecar metadata; use it only as a flagged last resort.

### Videos
- **FR-19** Preserve **every** video. Copy all of them to `_VIDEOS/<source>/` retaining original structure. Never merge, never drop.
- **FR-20** Flag suspected video duplicates (byte-identical, or same name and different content) in the report for manual sorting.
- **FR-21** Live Photo companion MOVs are **not** videos for this purpose; they follow their still.

### Output
- **FR-22** Write copies into `YEAR/MONTH/` with resolved time and location embedded in EXIF/XMP/QuickTime tags, including an explicit UTC offset, so re-import into Apple or Google Photos yields correct dates and map placement.
- **FR-23** Verify every written file: it opens, its pixels match the source, and the tags read back as intended.
- **FR-24** Emit a per-input-file manifest accounting for 100% of inputs: canonical, duplicate-of-X, burst-collapsed-into-X, variant-of-X, video-preserved, in-review, or skipped-with-reason.
- **FR-25** Route unresolved cases — ambiguous clustering, irreconcilable metadata conflict, corrupt file — to a **review queue** with a visual contact sheet, rather than guessing.

## 7. Non-functional requirements

- **NFR-1 Never delete.** Output to a new tree. Deleting originals is the user's separate manual step. No `--delete` flag in v1.
- **NFR-2 Dry-run by default.** Writing requires opting in.
- **NFR-3 Resumable.** 10k–50k files; a crash at 80% must not mean starting over.
- **NFR-4 Auditable.** Provenance is a user-facing feature, not a debug log. It is what lets someone check *why* their photo now claims to be from Tokyo.
- **NFR-5 Deterministic.** Same inputs → byte-identical output tree and identical manifest, regardless of the machine's timezone or locale.
- **NFR-6 Loud about failure.** "412 photos still have no location" is a feature. Silently guessing is the cardinal sin of this category.
- **NFR-7 Scale.** 10k–50k files without quadratic memory. (The current N² distance matrix allocates ~160 GB at 50k — see PLAN §9.)
- **NFR-8 Tunable, not magic.** Thresholds in one config, validated against a labelled corpus.

## 8. Acceptance criteria

1. **Zero merges of genuinely different scenes.** The hard failure — a missed duplicate costs disk, a false merge loses a photo forever. Burst collapse is *not* a false merge: it is an explicit, reported, reversible decision (FR-8–10).
2. Contact-sheet sample of 20 clusters shows no false merges.
3. Every output opens in Apple Photos with correct date and map location.
4. Re-running produces a byte-identical output tree and identical manifest, **on a machine set to a different timezone**.
5. The manifest accounts for 100% of input files.
6. `_VIDEOS/` count equals the total real video count across all sources — nothing lost.
7. Every Live Photo `.MOV` in the dated folders has a same-stem image beside it.
8. Originals still present and untouched in all three source trees.

## 9. Out of scope — permanently

Face recognition, editing, album management, semantic organisation, re-uploading to
any cloud, being a photo library. **This is a migration tool.** Someone will ask for
each of these. The answer is no, and that answer is written into the README on day one.

## 10. Settled decisions

| Question | Decision |
|---|---|
| Original + edited version | Keep both, linked via `derived_from`. Collapsible later by flag. |
| **Videos** | **Preserve all, never dedupe.** Copy to `_VIDEOS/<source>/`, flag suspected duplicates for manual sorting. (Supersedes an earlier decision to dedupe videos.) |
| **Bursts** | **Collapse to the sharpest frame** — but only on positive burst identification, always reported, reversible with `--keep-bursts`. |
| Output form | Real file copies, metadata embedded. Sources untouched. |
| Layout | `YEAR/MONTH/`. |
| **Phase 2 (open source)** | **Yes — a real goal.** Catalog, resume, `--explain`, undo manifest and the fixture suite are built in Phase 1 rather than retrofitted. |
| Scale | 10k–50k files. Quadratic approaches are out. |
| Takeout parsing | Accept GPTH-Neo output as a first-class input; keep the built-in sidecar reader as a fallback. Do not maintain a Takeout parser. |
| Stack | Python 3.13 (miniforge, present), exiftool, Pillow + pillow-heif, OpenCV, SQLite. |
| Machine learning | **None.** Classical CV only. Semantic embedding models collapse exactly the distinctions this task depends on. See PLAN §8b. |
| Licence | Apache-2.0 — matches GPTH, keeps the door open to upstreaming fixes to Neo. |
