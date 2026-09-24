# Changes

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
  build and test scripts find Xcode via `xcode-select` and say what they need (26–28).
- Icon-only buttons have VoiceOver labels; the minimum window is 1000 × 680 (part of 20).

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
