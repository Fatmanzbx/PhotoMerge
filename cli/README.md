# PhotoMerge

Merge photos scattered across a Mac, an iPad, and Google Photos into one
deduplicated library that keeps the best pixels **and** the best metadata.

## The problem

> Photos scattered across several sources — Apple Photos, Google Photos, old folders —
> with some photos in every source, some in only one, some several times at different
> qualities. Some copies carry the time and place they were taken; some don't; some
> disagree. The goal: one folder with every photo exactly once, with the correct time
> and place.

## The core insight

**A photo's best-pixels copy and its best-metadata copy are frequently not the same file.**

The Mac original is full resolution but may have no GPS. The Google copy is
downscaled and re-encoded, but its JSON sidecar knows the shot was taken in Tokyo on
2020-08-11. Any tool that keeps the best file and deletes the rest throws that
location away permanently.

So: **cluster by content → pick best pixels → union the metadata across the cluster → write it back.**

## What it does

One tree, `YEAR/MONTH/`, where every photo appears once, at the highest quality
available, carrying the best time and GPS available from *any* copy. Videos are all
preserved, unmerged, under `_VIDEOS/<source>/` for manual sorting. Nothing is ever
deleted from the sources.

**Phase 1** is a personal migration: get one real library right, once.
**Phase 2** is an open-source tool, gated on Phase 1 actually working (PLAN §12).

## Decisions

| | |
|---|---|
| **Videos** | Preserve all, never dedupe. Suspected duplicates flagged for manual sorting. |
| **Bursts** | Collapse to the sharpest frame — but only on positive identification, always reported, reversible with `--keep-bursts`. |
| **Edited copies** | Keep both original and edit, linked via `derived_from`. |
| **Output** | Real file copies, metadata embedded, `YEAR/MONTH/`. Sources untouched. |
| **Scale** | 10k–50k files. No quadratic approaches. |
| **Deletion** | Allowed — everything is backed up online. Gated on the superseder being written and verified. Two-stage: `.trash/` then `reclaim`. |
| **Disk** | 47 GB free vs. 37.1 GB merged. `--copy` fits and keeps the run repeatable; `--move` is the fallback. |
| **Source priority** | A tiebreak only, never ahead of format/pixel scoring — Google holds the HEIC original for ~1,646 photos Apple has only as JPEG. |
| **Target** | A **new** Apple Photos library on this Mac (managed, not referenced). Metadata embedded, Live Photo pairs preserved by `ContentIdentifier`, imported via `osxphotos import`. |
| **Motion Photos** | Converted to real Live Photos (remux + shared `ContentIdentifier`) — experimental, validated on 5 pairs first. |
| **Takeout parsing** | Built-in sidecar reader — measured **98% match, zero orphans** on the real export (PLAN §0), so GPTH-Neo pre-processing isn't needed. Neo stays a Phase-2 input option. |
| **File typing** | By magic bytes, never by extension — the real export contains extensionless MOVs and `.MP` motion videos. |
| **Machine learning** | None. Classical CV only — see PLAN §6. |
| **Stack** | Python 3.13, exiftool, Pillow + pillow-heif, OpenCV, SQLite. |
| **Licence** | Apache-2.0 (matches GPTH, allows upstreaming fixes to Neo). |

## Principles

This tool touches irreplaceable data. Correct algorithms are table stakes;
**trustworthiness is the product.**

1. **Delete only what is provably superseded.** A file is unlinked only once the file replacing it is written *and* verified — pixel hash matched, tags read back. Everything has an online backup, and disk is the binding constraint (§Space), so reclaiming is part of the run rather than a manual afterthought.
2. **Dry-run by default.** Writing requires opting in.
3. **Every decision auditable.** Provenance — which file each final value came from — is a user-facing feature, not a debug log. It's what lets you check *why* a photo now claims to be from Tokyo.
4. **Loud about failure.** "412 photos still have no location" is a feature. Silently guessing is the cardinal sin of this category.
5. **Deterministic.** Same inputs → identical output, regardless of the machine's timezone.
6. **Resumable.** A crash at 80% must not mean starting over.

## Out of scope, permanently

Face recognition, editing, album management, semantic organisation, cloud upload,
being a photo library. **This is a migration tool** — it's allowed to be finished.
Someone will ask for each of these. The answer is no.

## Space

Measured 2026-09-17: **47 GB free**. Sources total **60.4 GB** (Google 42.7 + Apple
17.7); the merged result is estimated at **37.1 GB**, freeing ~23 GB.

**But the destination is Apple Photos, which copies files into its library.** Sources
60.4 + `RESULT/` 37.1 + library 37.1 = **134.6 GB against 47 GB free.** Copy-mode would
leave 9.9 GB free before the import even starts.

So: **`--move`**, sequenced so the irreversible step comes after review —

| Step | Free after |
|---|---|
| 1. Analyze → catalog (read-only, ~100 MB) | 47 GB |
| 2. **Review and tune here** — repeatable while sources are intact | 47 GB |
| 3. Materialize `--move` | ~70 GB |
| 4. Import into a new Photos library | ~33 GB |
| 5. Verify import report vs. manifest | ~33 GB |
| 6. Delete `RESULT/` — only what the report confirms imported | ~70 GB |
| 7. Delete the old Photos library | +its size |

All threshold work happens at step 2, while every source file still exists. The move
is one irreversible commit made *after* the decisions are reviewed.

**The trade-off, stated plainly:** once files are moved and superseded copies unlinked,
the analysis cannot be re-run at a different threshold. **Dry-run and review contact
sheets before the first `--move` run.** The catalog survives, so `--explain` and the
manifest still work — but the inputs to a re-clustering will be gone.

**Work in rounds.** All sources cannot be on disk simultaneously:

1. **Google** alone → `RESULT/` in move mode. Frees ~6 GB and leaves one clean tree.
2. **Mac**, exported in year batches; each batch merged into `RESULT/` and deleted before the next.
3. **iPad**, same way.

This works because `RESULT/` is itself just another source in the catalog on the next
round, and the catalog persists between them.

---

# Runbook

## 0. Prerequisites

```bash
brew install exiftool     # required; Python EXIF writers are unreliable for HEIC/MOV
pip install -e .          # photomerge itself, plus pillow, numpy, pillow-heif, opencv
pip install pytest        # to run the test suite
```

exiftool 13.55, ffmpeg, brew and Python 3.13 are installed on this machine.

Run the tests before trusting a run — they build their own fixtures and need no
photos of yours:

```bash
python3 -m pytest tests -q
```

## 1. Collect into a staging tree

```
~/PhotoMerge/{mac,ipad,gphotos}/
```

### Mac — `--exiftool` is the flag that matters

```bash
brew install osxphotos
osxphotos export ~/PhotoMerge/mac --download-missing --exiftool --touch-file
```

**Dates and locations you corrected by hand inside the Photos app live in the Photos
database, not in the image files.** Without `--exiftool` they are silently dropped on
export, and no downstream cleverness can recover them. Highest-stakes step in the
process. `--download-missing` pulls originals that exist only in iCloud. Never reach
into the `.photoslibrary` bundle directly.

> **This has not been done yet on this Mac.** `Takeout/apple_export` is the same
> library (≤5% different) but exported without `--exiftool`: one flat folder, 6,123
> JPEG, **zero HEIC**, zero `.AAE`. The library itself is still at
> `~/Pictures/Photos Library.photoslibrary` (22 GB), so re-exporting is a strict
> upgrade of the same photos — and it is the only step here that cannot be redone
> later from the files alone. PLAN §13.

### iPad — cable, not AirDrop

Connect by cable, open **Image Capture**, import to `~/PhotoMerge/ipad/`. AirDrop can
strip location depending on the share-sheet toggle, and thousands of items will fail
partway through.

### Google Photos

takeout.google.com → Google Photos only → extract to `~/PhotoMerge/gphotos/`.

**Do not delete the `.json` files.** Capture time and GPS live in those sidecars, not
in the JPEG EXIF — they're the whole reason locations can be recovered for photos the
Mac copies never had. Takeout is internally messy (the same photo in both an album
folder and `Photos from 2019/`); that's normal.

**Already catalogued** (2026-09-17): 12,610 media, 43 GB, 2015–2026. Sidecar match
**100%**, no orphans, no filename truncation — see PLAN §0. Pre-processing with
GooglePhotosTakeoutHelper_Neo is **not** needed here; it stays a fallback for other
people's exports in Phase 2.

## 2. Catalog the sources, then look at what you have

Stage 1 walks the sources; stage 2 hashes every file and reads its metadata. Neither
writes anything outside the catalog, and both are safe to interrupt and re-run — an
unchanged file is never re-read.

```bash
photomerge scan --src ~/PhotoMerge/mac --src ~/PhotoMerge/ipad --src ~/PhotoMerge/gphotos
photomerge extract
photomerge status
```

`--src` order sets source priority, which is a **tiebreak only** — it never overrides
pixel count or format tier.

`status` is the survey: counts by source and by real (magic-byte) type, **sidecar
match rate per source**, where capture times and GPS actually come from, and the
duplicate signal before any clustering. Every threshold below rests on assumptions it
either confirms or kills, so read it before tuning anything.

Two results worth checking on your own library, because they decided the design here
(PLAN §0): how many files have **no capture time except in a Takeout sidecar** (753,
4%, on this library) and how many have **none but mtime** (zero here — if this is not
near zero for you, dates are guesses and §3's `datetime_from` column matters a lot
more).

```bash
photomerge status --errors     # anything that failed to read, with the reason
```

Scan is ~30 s, extract ~8 min and cluster ~4 s for 19k files; a rescan is under a
second.
Google Takeout and the Apple export are both catalogued (PLAN §0). Re-run once
`mac/` and `ipad/` are populated.

## 3. Cluster, then read the dry run

```bash
photomerge cluster
photomerge report --out .
```

`cluster` groups files that are the same photo. Today it runs only the two **certain**
tiers — equal bytes, and equal pixels after decoding — so there is no threshold to get
wrong and no way to merge two photos that merely look alike. It also pairs Live Photos
and Motion Photos, which is why the movie half of a Live Photo is never counted as a
video.

`report` writes `photomerge_report.csv` (one row per input file) and `manifest.json`
(what would be kept and dropped). **Neither writes anything to your photos.**

`--src` order is a **tiebreak only** — it never overrides pixel count or format tier.
On this library it nonetheless settles 5,621 of the 5,807 merged clusters, because
their members are byte-identical: everything above it is tied, and a choice between
two identical files cannot be wrong. Format and size decide 6. The clusters where the
ordering genuinely matters — the 1,671 stems holding both a HEIC and a JPEG — are not
merged yet; that is the perceptual tier, and it is not built.

Then read `photomerge_report.csv`:

| Column | What to check |
|---|---|
| `cluster_size` | >1 is a merge decision. Spot-check. |
| `reason` | Why that file won or lost its cluster, in words. |
| `method` | `exact` = same bytes. `pixel` = same image, different container. |
| `outcome` | `canonical` kept · `duplicate` dropped · `companion` follows its still · `review` refused |
| `datetime_from` | `mtime (unreliable)` means the date is a guess. Count these. |
| `own_gps` | Empty means this file knows no location — a sibling may still. |

## 3b. Resolve the metadata

```bash
photomerge resolve
photomerge report --out .
```

Decides each merged asset's date, timezone, location and camera from everything its
copies claimed, keeping the rejected values beside the chosen one. Takes seconds.

New columns appear in the CSV: `final_datetime`, `final_offset`, `final_gps`, and the
two that matter most when something looks wrong:

| Column | What it means |
|---|---|
| `datetime_note` | `date_conflict` — copies disagreed by more than a day; the earliest was kept. **Read these.** |
| | `tz_resolved` — a whole-hour gap treated as a timezone, not a conflict |
| | `tz inherited from the nearest dated photo (… away)` — the gap is stated; a wide one says so |
| `gps_note` | `gps_conflict` — fixes more than 5 km apart |
| | `inferred from …` — **this photo had no location**; it took one from the rest of its day. Written as `GPSProcessingMethod=ESTIMATED`, so it is always distinguishable from a real fix. `--no-infer-location` turns it off. |

Two rules here are worth knowing about, because they override the precedence table
(PLAN §4.1). **The earliest plausible claim wins a real disagreement**, because
copying and re-encoding only ever push a timestamp later. And **a timestamp shared by
dozens of unrelated photos is treated as a batch stamp**, not a capture — on this
library 1,428 EXIF dates sat in a four-minute window left by a phone restore.

Open **`report.html`** first: it leads with metadata coverage before and after, which
is the number that answers "did this work". On this library: a capture time on 100%
either way, a timezone offset 93.3% -> **100%**, a location 71.1% -> **76.6%**.

Ask why any single file ended up where it did, from either direction:

```bash
photomerge explain IMG_7868.HEIC        # what happened to this source file?
photomerge explain 20241127_114817      # where did this output file come from?
```

It answers from the catalog rather than from the pixels, so it still works after the
duplicates have been reclaimed.

```bash
photomerge --src ~/PhotoMerge/mac --src ~/PhotoMerge/ipad --src ~/PhotoMerge/gphotos \
           --out ~/PhotoMerge/RESULT --dry-run
```

Then read `photomerge_report.csv`:

| Column | What to check |
|---|---|
| `cluster_size` | >1 is a merge decision. Spot-check. |
| `burst_collapsed` | Sanity-check against how much you actually burst-shoot. |
| `datetime_from` | `mtime(unreliable)` means the date is a guess. Count these. |
| `tz_resolved` | Times fixed by timezone reconciliation. Check a few taken abroad. |
| `borrowed` | Which files needed metadata from a sibling, and from where. |
| `final_gps` | Empty means location is gone for good. Count these. |
| `review_reason` | Everything the tool refused to decide. Read all of these. |
| `dup_note` | Video duplicate hints for the manual pass. |

## 4. Calibrate

dHash Hamming distance decides how many pairs get *considered*; the verification
cascade decides which of them actually merge. Widening the radius costs time and finds
a few more duplicates — it does not loosen safety, because nothing merges without
surviving verification.

**Default 4**, calibrated on this library (PLAN §3.1-C): it finds 2,945 of the 2,983
duplicate assets that radius 6 finds, for three quarters of the work. The largest group
formed measured 6 files at *every* radius tested, so raising it does not risk the
runaway chains a raw similarity graph would produce. Raise it to 6 if you can see real
duplicates being missed; lower it to 2 if you want the run to finish sooner.

Whatever you pick, read the review queue — those are the pairs the tool refused to
decide.

```bash
photomerge verify --sample 20
```

Tiles every member of 20 random multi-file clusters into scannable PNGs. Thirty
seconds of looking beats an hour of CSV rows, and it's the only way to build real
confidence in the threshold. Re-running after a change reuses the catalog — hashes
aren't recomputed.

## 5. Real run

Drop `--dry-run`, add `--apply --move`. Canonical files are renamed into `RESULT/`,
metadata written with exiftool, superseded files moved to `.trash/`. Nothing is
unlinked yet.

```bash
photomerge --src ... --out ~/PhotoMerge/RESULT --apply --move
photomerge reclaim --confirm      # only after §6 passes — this is the irreversible step
```

## 5b. Import into Apple Photos

Use `osxphotos import`, not drag-and-drop — it sets albums, skips duplicates, reports
what happened, and handles Live Photo pairs explicitly:

```bash
osxphotos import ~/PhotoMerge/RESULT --walk --skip-dups --report import.csv
```

Into a **new** library (Option-launch Photos → *Create New Library*) — the existing one
already holds ~6,000 of these photos. Leave "Copy items to the Photos library" **on**;
`RESULT/` gets deleted afterwards and a referenced library would break with it.
Terminal needs Full Disk Access.

Apple Photos **ignores XMP sidecars and folder structure** on import, which is why
metadata is embedded and why albums have to be requested explicitly (`--album`) rather
than inferred from directories.

Then reconcile `import.csv` against the manifest and delete from `RESULT/` **only what
the report confirms imported** — anything Photos rejected stays.

## 6. Verify before deleting anything

- [ ] Output count ≈ expected unique count; no catastrophic over-merge
- [ ] Contact-sheet sample of 20 clusters shows no false merges
- [ ] Burst collapses spot-checked — the kept frame is the sharp one
- [ ] 10 files checked in `exiftool`: `DateTimeOriginal`, `OffsetTimeOriginal`, `GPSPosition` present
- [ ] Photos taken abroad show correct local time, not shifted by the offset
- [ ] Every `.MOV` in the dated folders has a same-stem image beside it
- [ ] `_VIDEOS/` count equals total real videos across all sources — nothing lost
- [ ] A few outputs open in Apple Photos / a map viewer and land where expected
- [ ] Live Photo pairs re-paired *in Photos* — not just same-stem on disk
- [ ] `.trash/` contents spot-checked before `reclaim --confirm`

**Verify before `reclaim`.** Disk is the constraint here, not caution — but the online backup is the safety net, so confirm it actually covers what you are about to unlink.

## 7. Permanent home

1. **Import `RESULT/` into Apple Photos + iCloud Photos** — the iPad syncs and the three-way split never recurs. Costs storage.
2. **Plain folder tree + backup** — zero lock-in, zero automation.
3. **Self-host immich** — only worth it to replace the whole cloud stack.

## 8. Keep an edge-case log

Every time a photo comes out wrong, write down **what shape of input caused it**, not
just the fix: `-edited` variants, truncated sidecar names, HEIC without EXIF,
screenshots with no capture time, messaging-app photos with stripped metadata,
timezone drift abroad, bursts not recognised as bursts.

**This log is the actual asset.** If Phase 2 happens it's the thing nobody can get
without having done Phase 1 for real — and each entry becomes a test fixture.

**Written up in [`BUILDLOG.md`](../docs/BUILDLOG.md)** — 14 entries from the first real run,
plus a record of where `PLAN.md` was wrong and why. Read §2 of it before trusting any
threshold in this repo on a library that is not this one.
