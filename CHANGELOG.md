# Changes

## 1.0.2 — 2026-09-24

The review's second round ([`review.md`](review.md), *Round 2*) checked 1.0.1 and found
two of its fixes incomplete and one regression. All closed here.

- **Blank frames can no longer chain two moments together (R1).** The capture-instant,
  shape and blank-frame guards are now one predicate that every matching tier consults,
  so tier C cannot join what tier B refused. Two dated black frames and an undated blank
  GIF stay three photos; a blank pair is "unverifiable", not an edit to review.
- **The manifest root has one spelling (R2).** 1.0.1 standardised the destination with a
  function whose result depended on whether the path existed yet, so under `/tmp` or
  `/private/tmp` the first write and every later one disagreed and Undo removed nothing.
  The root is now spelled by its text alone, in one place, and used everywhere the
  manifest is written or read. The crash suite runs one round from the other spelling.
- **A rescan re-attaches manifest rows instead of orphaning them (R3).** Rows carry the
  content hash of their source; a file with a new id or path after a rescan or rename
  finds its row again. Only a row with no such file goes, and its written file with it.
- **Date-range place rules need a real date (R4).** A file dated only by its copy date
  matches folder rules only, and no rule-given place is written into it.
- **Sidecars are not "unrecognised" (R5).** `.json`, `.aae`, `.xmp` and other companions
  are read as evidence and no longer counted as files the app cannot read.
- **A destination with files the manifest does not know is refused (R6).** After
  *Clear*, writing into the old destination would have doubled the library.
- **WebP keeps its EXIF (R8).** Only GIF is written XMP-only.
- **Undo after Tidy waits for the rescan instead of doing nothing (R13).**
- Dead code from the old Review step removed (R11); the tip banner's close button has a
  VoiceOver label and `test.sh` finds Xcode and Python like `build.sh` (R10).

Not changed: existing 1.0.0 catalogs keep `INTEGER PRIMARY KEY` on `file` (R7). Ids are
reused there only after *Clear*, which now also empties the manifest and trash ledger, and
every row is checked by path and content anyway; rebuilding the table under live foreign
keys is more risk than the remaining exposure. One SQLite connection (R9) as before.

## 1.0.1 — 2026-09-23

A pre-release code review of 1.0.0 ([`review.md`](review.md)) found 32 things; this
release closes the ones that could lose or misplace a photo, and most of the rest.

**Correctness**

- Pixel-identical matching (tier B) now applies the same guards as look-alike matching:
  two files with different capture instants, different proportions, or blank frames with
  no dates are never one photograph. Two black frames from different days and a GIF
  used to merge (finding 1).
- Nothing is inferred from a file's copy date any more: a photo dated only by its
  modification time takes no place from "the same day" and no zone from its
  neighbours, and no worked-out place is written into such a file (finding 2).
- The clean library follows the grouping: after a keeper change or regroup, the old
  kept copy is removed from the output (if still as written) instead of a `_2` appearing
  beside the new one; manifest rows whose file id now points elsewhere are dropped;
  new catalogs never reuse a file id; *Clear* forgets the manifest, trash ledger, groups
  and results too (findings 3, 4).
- Camera RAW files keep their own extension (`.nef`, `.arw`, `.cr2`, `.dng`…) instead of
  becoming `.tif`; AVIF keeps `.avif` (finding 6).
- GIF and WebP get their dates and places in XMP, which they can carry, so they are no
  longer excluded from a clean library as "the date did not take" (finding 10).
- The undo snapshot no longer includes the write destination and options, so an
  undo cannot point the manifest at another folder (finding 12); a snapshot that cannot
  be read aborts the undo registration instead of emptying a table on undo (finding 30).
- Day and folder centres are computed on the sphere, so fixes either side of 180°
  no longer average to the wrong hemisphere (finding 31).
- File dates are shown in the local zone, not UTC (finding 21); the output root is
  standardised, so a trailing slash no longer corrupts relative paths (finding 22).

**What the app tells you**

- Files it does not read — AVI, MKV, WMV, PSD, unknown RAW containers — are counted
  per folder, with their extensions, instead of vanishing (finding 5).
- A folder macOS would not let the app read is reported as such, not as an unplugged
  drive (finding 16).
- The time-zone check offers two corrections: *Correct* (the moment was right, the
  clock shown moves) and *Keep the clock* (the clock was right, the moment moves), with
  a note on which is which (finding 13).
- The Duplicates list says "300 of N" when there are more groups than it shows (18).
- A grouping or resolving failure is reported instead of looking like success (15).

**Resilience and performance**

- A catalog that will not open shows a recovery screen with *Put it aside and start
  again* instead of crashing on every launch (finding 7).
- Tidy, Put back and Undo write run off the main thread with progress; files are
  hashed in 4 MB pieces, and a kept copy is checked once per group rather than once per
  duplicate (finding 8).
- Another Photos library found inside a source is skipped as a package, so its
  thumbnails no longer appear as duplicates of its originals (finding 11).
- Place-name search folds the 34,000 names once at load, not on every keystroke (17).

**Distribution and docs**

- The install guide now gives the macOS 15 path (System Settings → Privacy & Security →
  Open Anyway); right-click → Open remains for macOS 14 (finding 9).
- Doc numbers corrected (⌘1–⌘7, ~30 MB); the Intel build is labelled untested on Intel;
  `build.sh` finds Xcode via `xcode-select` and the test scripts say what they need
  (26–28). (`test.sh` followed in 1.0.2.)
- Two of the three icon-only buttons gained VoiceOver labels; the minimum window is
  1000 × 680 (part of 20). (The third followed in 1.0.2.)

**Not changed, on purpose or for now**

- One SQLite connection for all threads (finding 14): readers can see a regroup in
  progress; the UI refreshes after. A read-only connection is the right fix and is next.
- Deprecated AVFoundation calls and Swift 6 warnings (finding 19).
- Fixed type sizes rather than the system text size (finding 20): the sizes were set
  by hand at the user's request, 1.5× the system's.
- Live Photo pairs can still split into `X_2.heic` + `X.mov` on a second run after a
  collision (finding 23); Photos re-pairs them by content identifier.
- Thumbnails still decide "video" by extension (finding 24).
- ExifTool runs on the system Perl (finding 29), by design; the Save step refuses
  cleanly if it is missing.

## 1.0.0 — 2026-09-23

First release.
