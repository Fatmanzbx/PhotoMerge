# PhotoMerge — Plan

Consolidating photos scattered across a Mac, an iPad, and Google Photos into one
deduplicated library that keeps capture time and GPS — then turning that into an
open-source tool.

**Phase 1** is a personal migration: get my own ~few-thousand photos right, once.
**Phase 2** is a product decision, and it should only start if Phase 1 actually works.

---

# Phase 1 — Solve my own library

## Goal

One folder tree, organized `YEAR/MONTH/`, where:

- every photo that exists in any of the three sources appears exactly once,
- each surviving file is the highest-quality copy available,
- each surviving file carries the best capture time and GPS available *from any copy*,
- no original is deleted until I have verified the result,
- videos are all preserved, unmerged, for manual sorting.

## The core insight driving the design

> A photo's best-pixels copy and its best-metadata copy are frequently **not the same file**.

The Mac original is full resolution but may have no GPS. The Google copy is
downscaled to 60% quality but its JSON sidecar knows the shot was taken in Tokyo on
2020-08-11. Any tool that simply "keeps the best file and deletes the rest" throws
the location away permanently.

So the pipeline is: **cluster by visual content → pick best pixels → union the
metadata across the whole cluster → write it back.**

## Current state

`photomerge.py` exists and runs. Verified against synthetic fixtures:

| Case | Result |
|---|---|
| Byte-identical copies across sources | Collapsed to one ✅ |
| Recompressed copy (q95 vs q60) | Clustered, original kept ✅ |
| Downscaled Google copy (1200×900 vs 600×450) | Clustered, original kept ✅ |
| Mac original has time but no GPS; Google JSON has GPS | GPS borrowed into the Mac original ✅ |
| Mac original has no EXIF at all; Google JSON has both | Time + GPS both borrowed ✅ |
| Nothing anywhere has GPS | Reported as "still no GPS", not guessed ✅ |
| Live Photo `.HEIC` + `.MOV` pair | Kept together, same basename, not sent to video pile ✅ |
| Real videos | All preserved under `_VIDEOS/<source>/`, duplicates flagged not deleted ✅ |
| GPS DMS ↔ decimal round-trip | 37.7749 read back exactly ✅ |

## Prerequisites

```bash
brew install exiftool          # required — Python EXIF writers are unreliable for HEIC/MOV
pip install pillow numpy pillow-heif
```

`exiftool` is non-negotiable. Everything else has a fallback.

## Step 1 — Collect all three sources into a staging tree

Target layout:

```
~/PhotoMerge/
  mac/
  ipad/
  gphotos/
```

### 1a. Mac

If the photos live in the Photos app:

```bash
brew install osxphotos
osxphotos export ~/PhotoMerge/mac --download-missing --exiftool --touch-file
```

`--exiftool` is the important flag. Dates I corrected by hand inside the Photos app,
and locations added after import, live in the Photos database — **not** in the image
files. Without `--exiftool` those edits are silently dropped on export.

`--download-missing` pulls down originals that are currently only in iCloud.

Never reach into the `.photoslibrary` bundle directly to grab files.

For loose photos elsewhere on disk, just copy them in.

### 1b. iPad

Connect by cable, open **Image Capture**, select all, import to `~/PhotoMerge/ipad/`.

Do **not** use AirDrop:
- the Photos share sheet can strip location depending on the options toggle,
- several thousand items over AirDrop will fail partway through.

### 1c. Google Photos

Go to takeout.google.com, select Google Photos only, export as `.tgz` or `.zip`,
extract to `~/PhotoMerge/gphotos/`.

**Do not delete the `.json` files after extracting.** The capture time and the GPS
coordinates live in those sidecars, not in the JPEG EXIF.

Expect Takeout to be internally messy — the same photo commonly appears both in an
album folder and in a `Photos from 2019/` folder. That is normal and the dedup pass
handles it.

## Step 2 — Restore metadata into the Takeout files

The sidecar naming is fragile. Current Takeout exports name them
`IMG_1234.jpg.supplemental-metadata.json`, and the whole filename gets truncated at
51 characters, which breaks naive `<name>.json` matching.

Two options:

**Option A (preferred): let `photomerge.py` read the sidecars directly.** It already
does fuzzy sidecar matching and will pull `photoTakenTime` and `geoData` out. No
extra step.

**Option B: pre-process with GooglePhotosTakeoutHelper_Neo.** If my library is large
or oddly structured, run `gpth` first to merge sidecars into the files, then feed its
output to `photomerge.py` as the `gphotos` source.

Use the **Neo fork** (`Xentraxx/GooglePhotosTakeoutHelper_Neo`), not the original.
The original `TheLastGimbus/GooglePhotosTakeoutHelper` has not been pushed to since
January 2025 and has unanswered issues from 2026 still open. The Neo fork is actively
maintained and falls back to ExifTool when native EXIF parsing fails.

## Step 3 — Dry run

```bash
python3 photomerge.py \
  --src ~/PhotoMerge/mac \
  --src ~/PhotoMerge/ipad \
  --src ~/PhotoMerge/gphotos \
  --out ~/PhotoMerge/RESULT \
  --dry-run
```

`--src` order is priority order — earlier sources win ties.

Read `photomerge_report.csv`. Columns that matter:

| Column | What to check |
|---|---|
| `cluster_size` | Anything > 1 is a merge decision. Spot-check these. |
| `datetime_from` | `mtime(unreliable)` means the date is a guess. Count these. |
| `borrowed` | Which files needed metadata from a sibling, and from where. |
| `final_gps` | Empty means location is gone for good. Count these. |
| `dup_note` | Video duplicate hints for the manual pass. |

## Step 4 — Calibrate the threshold

Default is dHash Hamming distance ≤ 6. This is the single parameter most likely to
be wrong for my library.

- Lots of burst shots or similar compositions → lower to 3–4 (more conservative).
- Many re-encoded or resized copies not being caught → raise to 8–10.

**Build a contact-sheet sampler.** Pick 20 random clusters with `cluster_size > 1`,
tile every member of each cluster into a single PNG, and eyeball it. Thirty seconds
of looking beats an hour of reading CSV rows. This is the only way to build real
confidence in the threshold, and it should later become a built-in command
(see Phase 2).

## Step 5 — Real run

Drop `--dry-run`. The script copies (never moves), writes metadata with exiftool,
and leaves all three source trees untouched.

## Step 6 — Verify before deleting anything

Acceptance checklist:

- [ ] Output count ≈ expected unique count; no catastrophic over-merge.
- [ ] Contact-sheet sample of 20 clusters shows no false merges.
- [ ] Spot-check 10 files in `exiftool` — `DateTimeOriginal` and `GPSPosition` present.
- [ ] Live Photo pairs: every `.MOV` in the dated folders has a same-stem image beside it.
- [ ] `_VIDEOS/` count equals total real videos across all three sources (nothing lost).
- [ ] Open a few outputs in Apple Photos or a map viewer — locations land where expected.
- [ ] Originals still present and untouched in `~/PhotoMerge/{mac,ipad,gphotos}`.

**Keep the source trees for at least a month** before deleting. Disk is cheap; the
photos are not replaceable.

## Step 7 — Pick a permanent home

Options, in rough order of effort:

1. **Import `RESULT/` into Apple Photos and turn on iCloud Photos.** The iPad syncs
   automatically and the three-way split never recurs. Costs iCloud storage.
2. **Keep it as a plain folder tree** plus a backup. Zero lock-in, zero automation.
3. **Self-host immich.** Open-source Google Photos replacement, but it is a server —
   only worth it if I want the whole cloud stack replaced.

## Step 8 — Keep an edge-case log

Every time a photo comes out wrong, write down *what shape of input caused it*, not
just the fix. Examples of what belongs in the log: `-edited` suffix variants,
truncated sidecar names, HEIC without EXIF, screenshots with no capture time,
photos received over messaging apps with stripped metadata, timezone drift on
photos taken abroad.

**This log is the actual asset.** If Phase 2 happens, it is the thing nobody can get
without having done Phase 1 for real — and it is the test suite.

---

# Phase 2 — Open source it

Start this only if Phase 1 produced a result I actually trust with my own photos.

## The positioning thesis

The README's first paragraph writes itself:

> A photo's best-pixels copy and its best-metadata copy are frequently not the same
> file. Existing tools pick one file and discard the rest — along with whatever
> location and date only the discarded copies knew. PhotoMerge merges N sources into
> one library, keeping the best pixels and the union of the metadata.

That sentence is the entire differentiator. Everything else is implementation.

## The landscape, and where the gap actually is

| Tool | Scope | Status |
|---|---|---|
| GooglePhotosTakeoutHelper | Takeout → chronological folders | 5.5k+ stars, stale since Jan 2025, issues unanswered |
| GPTH **Neo** (Xentraxx fork) | Same, modernized, ExifTool fallback | Actively maintained |
| PhotoSweeper X | Single-machine dedup, macOS | ~$18, mature, closed source |
| dupeGuru / Czkawka | Generic dedup, cross-platform | Free, not photo-metadata-aware |
| Apple Photos built-in | Dedup within one Photos library | Free, ships with macOS |
| Mylio Photos | Multi-device consolidation + dedup | $240/yr for new users; dedup skips videos; does not read Takeout JSON |
| immich | Self-hosted library host | Free, but it's a server, not a migration tool |

**Every one of these is single-source or single-machine.** Nothing does
"N heterogeneous sources → one canonical library with metadata union."

## What NOT to build

**Do not write another Google Takeout parser.**

It is the dirtiest, most thankless part of the problem, it breaks every time Google
changes the export format, and GPTH Neo already maintains one. Rebuilding it means
inheriting an endless chase for zero differentiation — and that chase is precisely
what killed the original GPTH.

Instead: accept a GPTH-Neo output directory as a first-class input source, and keep
the built-in sidecar reader only as a convenience fallback for simple cases.

Scope discipline is the main risk control in this project.

## Core data model

Everything flows from one record type and one operation.

```
Asset:
    path, source, source_priority
    kind          : photo | video | live_companion
    content_hash  : sha256
    percept_hash  : dhash64            (photos only)
    pixels        : width * height
    metadata      : {datetime, lat, lon, alt, make, model}
    provenance    : {field -> exif | sidecar | filesystem | borrowed:<source>}
```

```
Cluster: a set of Assets believed to be the same photograph.
    winner   = argmax(pixels, filesize, -source_priority)
    metadata = field-wise union over the cluster,
               each field taken from the most trustworthy provenance available
```

Trust ranking for metadata provenance: `exif > sidecar > filesystem mtime`.

The provenance map is not a debugging aid — it is a user-facing feature. It is what
lets someone audit *why* their photo now claims to be from Tokyo.

## Separation guards (avoid over-merging)

Two visually similar photos are kept apart if:

- both have EXIF-grade timestamps more than 24h apart, or
- both have GPS more than 5km apart.

These prevent the classic failure where a perceptual hash collapses two genuinely
different shots of the same wall.

## Trust-first design principles

This tool touches irreplaceable data. Correctness of the algorithm is table stakes;
**trustworthiness is the product.**

1. **Never delete. Ever.** Output to a new tree. Deleting originals is always the
   user's separate, manual, second step. No `--delete` flag in v1.
2. **Dry-run is the default**, not a flag. Writing requires opting in.
3. **Every decision is auditable.** Ship the provenance report as a first-class
   artifact, not a debug log.
4. **Contact-sheet verification is a built-in command**, not a script in `/tools`.
   `photomerge verify --sample 20` should emit a PNG a human can scan in 30 seconds.
5. **Resumable.** Tens of thousands of files, a crash at 80% must not mean starting
   over. (GPTH Neo added this for good reason.)
6. **Loud about what it could not recover.** "412 photos still have no location" is
   a feature. Silently guessing is the cardinal sin of this category.

## Roadmap

### v0.1 — "works for me"
Phase 1's script, cleaned up. Multi-source, clustering, metadata union, provenance
CSV, videos passed through. Single `photomerge` CLI. No install story beyond
`pip install -e .`.

### v0.2 — "works for other people's messes"
- GPTH-Neo output as a declared input source type.
- `verify` subcommand with contact sheets.
- Resume from interrupted runs.
- Edge cases from the Phase 1 log, each with a regression test.
- Real HEIC coverage (my own library is a weak test set here).

### v0.3 — "trustworthy"
- Undo manifest: a JSON of every copy/write, enough to reverse a run.
- `--explain <file>` — print the full decision trace for one output.
- Configurable keep-policy (prefer resolution / prefer source / prefer oldest).

### v1.0
- Docs with real screenshots of the report and a contact sheet.
- Homebrew formula or a single-binary build. The audience for this problem is
  substantially non-technical; `pip install` will lose most of them.

**Explicitly out of scope, permanently:** face recognition, editing, album
management, being a photo library. This is a migration tool. Someone will ask for
each of these. The answer is no.

## Testing strategy

The synthetic fixture generator from Phase 1 is the foundation and should be
committed as part of the test suite. It can construct, deterministically:

- a high-res original with full EXIF including GPS,
- a byte-identical copy in another source,
- a recompressed copy at lower quality,
- a downscaled copy with EXIF stripped plus a Takeout-style JSON sidecar,
- a Live Photo `.HEIC`/`.MOV` pair split across two sources,
- videos byte-identical across sources and a recompressed variant.

Every edge case from the Phase 1 log becomes a new fixture. This gives a test suite
that runs in seconds without shipping anyone's actual photos — which matters, because
nobody can contribute a failing test case otherwise.

Property to assert on every run: **no input photo is unrepresented in the output**
(modulo intentional dedup), and **no output has metadata worse than the best input in
its cluster.**

## Maintenance boundary

GPTH did not fail technically. It was buried under unpaid support load: dozens of
open issues, a format that kept changing underneath it, and users treating a free
tool like a paid product.

Mitigations, decided up front:

- **Position as a one-shot migration tool**, not a library manager. A migration tool
  is allowed to be *finished*. A photo manager never is.
- **Delegate the volatile surface** (Takeout format) to GPTH Neo.
- **Issue template requires a reproducible fixture.** "It didn't work on my 200GB
  library" is not actionable and should be closed as such without guilt.
- **Write the "not planned" list into the README on day one**, so saying no later is
  citing policy rather than picking a fight.

## Naming and license

- Name should say what it does; `photomerge` is taken in several ecosystems, check
  PyPI and GitHub before committing.
- MIT or Apache-2.0. Apache-2.0 matches GPTH's license and keeps the door open to
  contributing fixes upstream to Neo.

---

## Decision gate between phases

Do not start Phase 2 until all of these are true:

- [ ] Phase 1 ran end-to-end on my real library.
- [ ] I trust the output enough to delete the source copies.
- [ ] The edge-case log has at least 5 entries that were genuinely surprising.
- [ ] I still want to maintain this in three months.

If the last box is unchecked, the right outcome is to publish the script as a gist
with a good README and stop there. That is a legitimate result, not a failure — a
documented dead end in a category full of abandoned repos is worth more than another
abandoned repo.
