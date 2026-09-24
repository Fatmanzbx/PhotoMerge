# PhotoMerge 1.0.0 — pre-release code review

> A second round, reviewing the 1.0.1 fixes (commit 6029aeb), is appended at the end of
> this file under **Round 2 — review of 1.0.1**.

Date: 2026-09-23. Scope: everything in this repository, with the Mac app (`app/`) reviewed in
full and the legacy Python CLI (`cli/`) reviewed lightly. Read-only: nothing in the repository
was modified. Running the build regenerated the gitignored `app/build/` folder.

What was run to support the findings:

- `app/build.sh` (passes; 30 compiler warnings), `app/test.sh` (422/422), `cli` pytest (160 passed)
- `Tests/known_library.py` + `build/tests known` + `Tests/check_known.py` (20/20)
- `Tests/crash_test.sh` with 3 kills and 1 round (all crash checks passed)
- Five synthetic-library experiments of my own, in a scratch directory, exercising the same
  `build/tests known|prep|actc` entry points the project's own tests use. Referred to below as
  exp1–exp5.

Every finding is marked **VERIFIED** (confirmed by running something or by tracing the code) or
**SUSPECTED** (plausible; what would confirm it is stated).

---

## 1. Project summary

PhotoMerge is a non-sandboxed, ad-hoc-signed SwiftUI Mac app with no Xcode project. A shell
script compiles `app/Sources/*.swift` with `swiftc`, bundles Homebrew's ExifTool as a Perl
subprocess, and makes a DMG. The engine is a single SQLite catalog in Application Support, one
connection shared by all threads, with a serial queue for writes. The pipeline is scan
(magic-byte sniff) → extract (sha256, dHash, 64×64 luminance thumb, EXIF, AVFoundation for video)
→ cluster (tier A byte hash, tier B pixel hash, tier C BK-tree neighbours verified by a
two-resolution pixel slope test, tier D video frames) → resolve (time, place, zone from EXIF,
Takeout sidecars, filenames, neighbours) → optional ballot, audit and manual entries. Two actions
touch disk: Act writes a verified copy under a temp name then renames, with a resumable
manifest; Tidy moves duplicates to the Trash with a restore path. Every user choice lives in
small catalog tables snapshotted for undo. The Python CLI under `cli/` is the legacy predecessor
and is not what ships. Tests are a hand-rolled harness in `Tests/main.swift`, a Python
known-answer library, and a kill -9 crash script. All of them pass on this machine.

---

## 2. Top 5 issues

1. **Tier B merges photos that were not taken at the same moment.** The pixel hash is a 64×64
   grey grid with no dimension, aspect or capture-instant check. In exp1 two black JPEGs from
   different days and a 200×200 GIF became one "same image" group, and the GIF inherited the
   JPEG's date. The Help text promises the opposite. A wrong merge is the one unrecoverable
   outcome, and this path bypasses the burst guard the README is built around.
2. **A place invented from a file's copy date is written into the file as GPS.** A photo whose
   only date is its mtime gets "same day, same place" from whatever was photographed on the day
   it was copied. Act then writes those coordinates into the clean copy by default. That breaks
   "read beats estimated" with permanent, wrong-looking metadata.
3. **The manifest does not follow the grouping, and file ids are recycled.** After a keeper
   change the old verified row stands and the new canonical is written beside it as `_2`, so the
   "one file per photograph" library contains a duplicate. Separately, `file.id` has no
   AUTOINCREMENT, so after Clear and re-add, stale `output` and `trashed` rows attach to
   unrelated new files, which are then silently never written or never tidied.
4. **Unrecognised media is dropped without a word.** AVI, MKV, WMV, MTS, Fuji/Olympus/Panasonic
   RAW, BMP and MOVs without an `ftyp` atom fail the sniff and are never recorded. The counts a
   user sees are of files the app chose to see. Someone saving a "clean library" from a folder
   of camcorder footage would lose all of it and not know.
5. **The install instructions do not work on current macOS.** The GUIDE tells people to
   right-click → Open. macOS 15 removed that override for unsigned apps. The app is ad-hoc
   signed and not notarized, so every downloader on Sequoia or Tahoe hits a dead end at step 3.

---

## 3. Full findings table

Sorted by severity.

| # | Severity | Category | Location | Problem | Why it matters | Suggested fix | Effort | Verified? |
|---|---|---|---|---|---|---|---|---|
| 1 | Critical | Correctness | `app/Sources/Clusterer.swift:230-233`, `Extract.swift:178-181` | Tier B unions on the 64×64 luminance hash with no `differentMoments` guard, no width/height check and no slope verification. Two solid JPEGs dated 2021-01-01 and 2021-01-02 plus a 200×200 GIF merged as "same image"; the GIF then inherited the JPEG's EXIF date. | Unrecoverable wrong merge; Tidy would trash them and Act omits them. Contradicts `HelpView.swift:26` ("Two photos taken a second apart are never duplicates, however alike"). | Apply the capture-instant guard to tier B; fold dimensions or aspect into the pixel hash; treat near-uniform thumbs as unverifiable. | S | VERIFIED (exp1) |
| 2 | Critical | Correctness | `Resolver.swift:433-453, 550-563`, `Act.swift:143-154` | Place and zone inference run for clusters whose `timeSource` is `mtime (unreliable)`. `noexif.jpg` (no metadata, mtime 2020-05-01) got Paris by "same day, same place" and a zone by "nearest dated photo"; the written `Undated/noexif.jpg` carries GPS 48.8583, 2.3511. | Invented GPS baked into files, indistinguishable from a real fix later. | Skip place and zone inference for mtime and date-only time sources, or never write places when the date source is a file date. | S | VERIFIED (exp1) |
| 3 | High | Correctness | `Act.swift:226-241` | `prepare` deletes only non-verified rows. A file that is no longer canonical keeps its verified row and its file on disk; the new canonical is planned and committed as `_2`. | The "clean" library contains duplicates after any keeper change or regroup between two write runs. | In `prepare`, mark verified rows whose file has lost its canonical/companion role; remove or report their files before planning. | M | VERIFIED (exp2) |
| 4 | High | Correctness | `Catalog.swift:38-50, 90, 107-110`, `Engine.swift:123-130` | `file.id` is `INTEGER PRIMARY KEY` without AUTOINCREMENT; `output.file_id` and `trashed.file_id` have no foreign key. After Clear, the first new file received id 1 and the old verified `output` row attached to it. | New photos silently treated as already written; `Tidy.plan` excludes new files whose id matches a stale `trashed` row. | Use AUTOINCREMENT; key manifest and trash rows by sha and path; clear `output`, `trashed`, `resolution` and `pair` in `removeAll`. | M | VERIFIED (sqlite experiment) |
| 5 | High | UX / Correctness | `Sniff.swift:22-52`, `Ingest.swift:142` | `Sniff.sniff` returns nil for AVI, MKV, WMV, MTS/M2TS, RAF, ORF, RW2, BMP, PSD, and QuickTime files without an `ftyp` atom; `Ingest.scan` `continue`s and records nothing. `camcorder.avi` vanished: scanned 10 of 11 files. `Kind.other` exists but is never produced. | Silent omission from the library the app calls complete; no UI count exists anywhere. | Record a `Kind.other` row, or a per-source "not recognised" count, and show it on the Add step and Sources pane. | M | VERIFIED for AVI (exp1); legacy MOV SUSPECTED (my `ftyp`-stripped sample was itself unreadable) |
| 6 | High | Correctness | `Act.swift:97-106` | `outputExtension` maps any TIFF-based RAW (NEF, ARW, CR2) to `.tif` and AVIF to `.heic`. `shot.NEF` was written as `Undated/shot.tif`. | RAW files renamed to an extension RAW converters will not open; AVIF mislabelled. | Keep the original extension for the tiff and heic families; only normalise extensions known to be wrong. | S | VERIFIED (exp1) |
| 7 | High | Resilience | `Engine.swift:77, 100` | `catalog = try? Catalog(url:)` then `staleChoices(catalog!)`. | A corrupt, locked or unwritable catalog crashes the app on every launch with no recovery path. Every other method guards `catalog`; this line does not. | Guard the unwrap; show an error and offer to move the catalog aside. | S | VERIFIED (trace) |
| 8 | High | Performance / UX | `Engine.swift:673-695, 618-625`, `Tidy.swift:72-75`, `Act.swift:421-422` | `tidy()`, `putBack()` and `undoWrite()` run synchronously on the main actor. `Tidy.run` loads each duplicate and its kept copy fully into memory with `FileManager.contents` and hashes them, re-hashing the kept copy once per duplicate. No progress, no cancel. | Minutes of frozen UI and multi-GB allocations on real libraries (a 4 GB video is read whole). | Run on a detached task with progress and stop; stream hashes; cache the kept copy's hash per cluster. | M | VERIFIED (trace) |
| 9 | High | Deploy / Docs | `docs/GUIDE.md:17-19`, `app/build.sh:579`, `app/make_dmg.sh` | Ad-hoc signature, no notarization; GUIDE step 3 says right-click → Open. macOS 15 removed that override for unsigned apps; the only path is System Settings → Privacy & Security → Open Anyway. | First-run failure for every downloader on current macOS. | Rewrite step 3, or sign with a Developer ID and notarize. | S (docs) / M (notarize) | SUSPECTED; confirm by downloading the DMG on a Sequoia or Tahoe Mac and following the GUIDE |
| 10 | Medium | Correctness | `Act.swift:131-141, 360-362` | GIF cannot carry EXIF. A name-dated GIF gets `EXIF:DateTimeOriginal` in its tag set; exiftool writes the XMP tags and reports success, then verification fails with "the date did not take: read back nothing". | Every dated GIF is excluded from the clean library and listed as failed. | Write XMP-only tags for GIF and verify against XMP. | S | VERIFIED (exp3) |
| 11 | Medium | Correctness | `Ingest.swift:116-118` | The enumerator descends into `.photoslibrary` packages found inside a source (no `skipsPackageDescendants`). `resources/derivatives` thumbnails were ingested and grouped as duplicates of their originals. | Inflated duplicate and "recoverable" counts; noise in the Duplicates step; Tidy refuses them but shows them. | Skip package descendants unless the source is the package's own `originals/`. | S | VERIFIED (exp1) |
| 12 | Medium | Correctness | `Catalog.swift:252`, `Engine.swift:571, 582-583` | The undo snapshot includes the whole `setting` table, which also stores `output_root`, `act_options` and the acks. | Undoing an unrelated choice made before the destination was picked reverts the write destination after files were written; `writtenCount` drops to 0 and the write Undo button disappears while the `output` rows remain. | Exclude `output_root` and `act_options` from the snapshot, or store them in their own table. | S | VERIFIED (trace) |
| 13 | Medium | Product | `Audit.swift:1-20`, `Resolver.swift:387-403`, `Guide.swift:53-57` | Correction assumes the instant was right and the offset wrong, so it moves the wall clock. When the wall clock was right and the offset wrong (a computer import stamping a home offset), the correction shifts hours of photos to the wrong local time. "Correct all" is the card's primary action and applies to every finding at once. | Systematic wrong times applied in bulk with one click. Partly a documented trade-off, but the default action is the risky one. | Make "Show me" the primary action, show a before/after sample in the card, and offer "keep the clock, change the offset". | M | VERIFIED (trace) |
| 14 | Medium | Concurrency | `Engine.swift:213-214, 563-566, 958-976` | `loadAudit`, `refreshActSummary` and `loadBallots` read on detached tasks over the same connection while `Pipeline.cluster` runs `DELETE FROM member; DELETE FROM cluster` inside a transaction. On one connection the readers see uncommitted state. | Transient wrong summaries and audit rows in the UI until the next refresh. | Open a second read-only connection for the UI, or sequence reads after the write task completes. | M | SUSPECTED; confirm by logging counts inside `Act.summary` during a regroup |
| 15 | Medium | Error handling | 118 `try?` across `Engine` (30), `Pipeline` (19), `Act` (19), `Catalog` (10), `Tidy` (9) | Catalog write failures (disk full, I/O error, locked) are swallowed; a throwing `Pipeline.cluster` leaves the stage at "done" with no groups. `Catalog.migrate` also swallows every error. | Users see nothing when the catalog stops persisting. | One error channel to `notice`; treat `Catalog.Err` in the stage wrappers. | M | VERIFIED (grep) |
| 16 | Medium | Privacy / UX | `GuidedView.swift:165-168, 228`, Info.plist in `build.sh` | "Add my Photos library" constructs the path rather than using an open panel, so no user-intent grant exists; Info.plist has no `NSPhotoLibraryUsageDescription`; a denied TCC prompt surfaces as "an unplugged drive?". | Confusing failure on the headline button. | Add the usage string; detect EPERM and say so; consider routing through NSOpenPanel. | S | SUSPECTED; confirm in a fresh user account by denying the prompt |
| 17 | Medium | Performance | `Resolver.swift:521-538, 549-564`, `Gazetteer.swift:99-110`, `FillView.swift:192-195`, `Engine.swift:1145-1184` | Zone steps 3 and 4 scan all observations or all known days per unzoned cluster; `Gazetteer.search` folds 34k names per keystroke on the main thread; `loadGroups` runs 301 queries on the main thread; `Tidy.plan`, `Manual.rows`, `refreshStats` also run on the main actor. | Fine at 10k files; degrades sharply toward the 100k the BK-tree comment targets. | Binary-search the sorted day list; pre-fold gazetteer names once; move list loads off the main actor. | M | SUSPECTED |
| 18 | Medium | UX | `Engine.swift:1145`, `Views.swift:219` | Groups are capped at 300 and the segment reads "Groups 300" with no "of N". | Users believe they have seen every group. | Show "300 of N" and page or scroll-load. | S | VERIFIED (trace) |
| 19 | Medium | Build | `VideoExtract.swift:37-76`, `Views.swift:1086`, `Engine.swift` | 13 deprecated synchronous AVFoundation calls (`duration`, `tracks`, `metadata`, `copyCGImage`); 23 warnings that become errors in Swift 6 (`Engine.workers` MainActor-isolated but used from workers, captured vars in concurrent closures). | Blocks a compiler upgrade; sync asset loads can stall extraction workers. | Migrate to `load(...)`; mark `workers` and `radiusChoices` nonisolated. | M | VERIFIED (build log) |
| 20 | Medium | Accessibility | `App.swift:142`, all views | Every font size is a literal from 14 to 36 pt; one `accessibilityLabel` in the whole app (`TimelineChart`); icon-only buttons (`minus.circle`, export) rely on `.help`; window minimum 1120×720. | Ignores system text size; VoiceOver reads thumbnails and buttons as nothing; does not fit small scaled displays. | Use text styles, label images and icon buttons, lower the minimum size. | M | VERIFIED (grep) |
| 21 | Low | Correctness | `Resolver.swift:294` | mtime is rendered with `wallClock(m, offset: 0)`, so a "file date" displays in UTC while labelled as a local time. `shot.NEF` showed 24 Sep 2026 00:22 while the local date was 23 Sep. | Wrong day shown for every file-dated photo when local time is behind UTC in the evening. | Render mtime in the local zone. | S | VERIFIED (exp1) |
| 22 | Low | Correctness | `Act.swift:373` | `rel = dest.dropFirst(root.count + 1)`; a root with a trailing slash records `020/05/20200501_100000.jpg`. `output.root` is also compared as a raw string, not standardised. | Undo and reconcile then cannot find the file. Unreachable via NSOpenPanel today. | Compute the relative path from the standardised URL; standardise `root` once. | S | VERIFIED (exp5) |
| 23 | Low | Correctness | `Act.swift:62-77, 367-372` | The clip shares the still's planned stem, but the `_2` collision bump at commit time is per file. | A Live Photo pair from a second run can land as `X_2.heic` and `X.mov`; Photos re-pairs by ContentIdentifier, but the naming promise is broken. | Resolve collisions per cluster before committing either file. | S | SUSPECTED |
| 24 | Low | Consistency | `Views.swift:1077, 1142` | `Thumbnails.render` and `Thumb.isVideo` decide "video" by extension while the rest of the app types by magic bytes. | Extensionless MOVs (present in the real Takeout export per `cli/PLAN.md`) and `.3gp` show a broken photo placeholder. | Pass `kind` from the catalog into `Thumb`. | S | VERIFIED (trace) |
| 25 | Low | Code quality | `Clusterer.swift:232`, `Catalog.swift:180`, `ExifTool.swift:87-97`, `Sniff.swift:7` | `r.tierC += 0`; `Catalog.hasColumn` unused; `ExifTool.read` and `version` used only by tests; `Kind.other` never produced. | Dead code misleads readers about intended behaviour. | Delete or wire up. | S | VERIFIED (grep) |
| 26 | Low | Build | `test.sh:618`, `build.sh:499, 556`, `Tests/crash_test.sh:15`, `Tests/*.py` | Hardcoded miniforge python path, Xcode at `/Applications/Xcode.app`, Homebrew Cellar globs; scripts call plain `python3`, which here is a system python without Pillow. | Build and test scripts work on this machine only. | Discover tools with `command -v`; document requirements; fail with a clear message. | S | VERIFIED |
| 27 | Low | Docs | `app/README.md:55, 437`, `docs/GUIDE.md:11` | ⌘1–⌘8 in one place, ⌘1–⌘5 in another; the code has 7 tabs. "About 20 MB of disk" for a 28 MB bundle. | Erodes trust in otherwise detailed docs. | Correct the numbers. | S | VERIFIED |
| 28 | Low | Deploy | `make_dmg.sh:645` | The x86_64 slice is cross-compiled and never executed or tested. | Intel is advertised as supported without evidence. | Run `./test.sh` under Rosetta or on an Intel Mac before each release. | S | SUSPECTED |
| 29 | Low | Deploy | `ExifTool.swift:33` | ExifTool runs on `/usr/bin/perl`, which Apple has deprecated as a bundled runtime. | A future macOS without Perl disables the entire Save step. | Watch for it; the "exiftool is missing" refusal already exists. Deliberate trade-off. | – | SUSPECTED |
| 30 | Low | Resilience | `Catalog.swift:256-288` | `Snapshot.take` swallows a failed SELECT as an empty row list; `apply` then executes `DELETE FROM <table>` and inserts nothing. | A transient SQL error at snapshot time could erase a decision table on undo. | Make `take` throw and abort the undo registration on error. | S | SUSPECTED; confirm by injecting a SQL error |
| 31 | Low | Correctness | `Resolver.swift:427-432, 469-473` | Arithmetic mean of longitudes for day and folder centres. | Fixes straddling ±180° average to the wrong hemisphere. | Average on unit vectors. | S | SUSPECTED |
| 32 | Low | Dependencies | `cli/pyproject.toml` | Lower-bound pins only, no lock file. | Legacy tool, clearly labelled as such; a deliberate trade-off. | Pin if the CLI is meant to be run by others. | S | VERIFIED |

---

## 4. Quick wins

Each is under about 30 minutes and closes a finding outright.

- Guard tier B with `differentMoments` and skip near-uniform thumbs. Closes finding 1.
- Skip place and zone inference when `timeSource` starts with `mtime`. Closes finding 2.
- Keep the original extension for the tiff and heic families in `outputExtension`. Closes finding 6.
- Replace `catalog!` with a guard and an error notice. Closes finding 7.
- Remove `output_root` and `act_options` from the undo snapshot. Closes finding 12.
- Rewrite GUIDE step 3 for macOS 15 and later. Closes finding 9 until notarization exists.
- Skip `.photoslibrary` descendants during the walk unless the source is the package. Closes finding 11.
- Show "300 of N" on the Groups segment. Closes finding 18.
- Render mtime in the local zone. Closes finding 21.
- Fix the ⌘ shortcut numbers and the bundle size in the docs. Closes finding 27.
- Delete `r.tierC += 0`, `hasColumn` and the unused `ExifTool` methods. Closes finding 25.

---

## 5. Structural concerns

- **Catalog identity is by rowid, but the product's promises are by content.** Decisions are
  keyed by sha, yet the manifest and the trash ledger are keyed by a reusable integer.
  Findings 3, 4 and the leftover rows after Clear all flow from this. Add AUTOINCREMENT,
  foreign keys or sha keys on `output` and `trashed`, and a schema version row so future
  migrations can be non-additive.
- **One connection for every thread.** The write queue protects writes, but readers on the main
  actor and on detached tasks see partial transactions and block on long ones. A read-only
  connection for the UI, plus moving every list load off the main actor, removes findings 8, 14
  and half of 17 together.
- **Inference does not know how good its inputs are.** The resolver tracks provenance as strings
  and each stage string-matches them. A small enum for time quality (read, name, instant, file
  date, entered) checked at every inference step would have prevented finding 2 and makes
  finding 13 tractable.
- **Errors have nowhere to go.** Add one error path from the stages to `notice` before adding
  features; today a failing catalog looks like success.
- **Distribution.** A Developer ID and notarization are the only way the download works without
  a support article. Do this before the next release, then remove the quarantine advice from
  the GUIDE.

Suggested order of attack: schema and manifest integrity (3, 4) → tier B and the mtime guard
(1, 2) → main-actor file work (8) → notarization (9) → concurrency and deprecation warnings
(14, 19).

---

## 6. What could not be assessed

- **The running UI.** The app was not launched or driven, so layout, focus order, keyboard
  flows and the Compare sheet are judged from code only.
- **Gatekeeper on a clean machine, Photos-library TCC behaviour, and the Intel slice.** Each
  needs a second Mac or a fresh user account.
- **Behaviour at 100k+ files.** The performance findings are extrapolated from the code. The
  10,913-file library in the README is the only measured data point.
- **Real RAW, CR3, AVCHD and legacy QuickTime samples.** The RAW test used a TIFF named `.NEF`;
  the `ftyp`-stripped MOV was itself unreadable, so the legacy-MOV case stays suspected.
- **The Python CLI beyond its tests.** It is labelled legacy and was treated as such: 160 tests
  run, command surface and destructive operations skimmed, nothing deeper.

---

## Appendix — experiment details

All experiments used synthetic images drawn with Pillow, tagged with exiftool, and videos from
ffmpeg, in a scratch directory outside the repository, through `app/build/tests`.

**exp1** — `known` on a folder containing: two dated, zoned, GPS-tagged JPEGs (Paris);
`noexif.jpg` with all metadata stripped and mtime 2020-05-01 12:00 UTC; a TIFF named
`shot.NEF`; `20200501_120000.gif`; `20200501_130000.png`; `camcorder.avi`; two solid-black JPEGs
dated one day apart; a nested `Nested.photoslibrary` with an original and a derivative thumbnail.
Results: 10 of 11 files scanned (the AVI absent); black1, black2 and the GIF in one "same image"
cluster; `noexif.jpg` resolved to "mtime (unreliable)" + "same day, same place" and written with
GPS 48.8583, 2.3511; `shot.NEF` written as `Undated/shot.tif`; the derivative grouped as a
duplicate of its original; mtime displayed as 2026:09:24 00:22:01.

**exp2** — `prep` + `actc` on one photo with a byte-identical backup copy, then roles swapped in
`member` (as a keeper change does), then `actc` again. Result: both
`2020/05/20200501_100000.jpg` and `2020/05/20200501_100000_2.jpg` on disk, both rows verified.
Then, on a copy of the catalog: `DELETE FROM file` and one new insert → the new row received
id 1 and the stale verified `output` row attached to it.

**exp3** — `known` on a name-dated GIF, a name-dated WebP and an ffmpeg MOV. Result: the WebP
wrote and verified; the GIF failed with "the date did not take: read back nothing".

**exp5** — `actc` with a destination ending in `/`. Result: `output.target` recorded as
`020/05/20200501_100000.jpg` while the file sits at `2020/05/…`.

---
---

# Round 2 — review of 1.0.1

Date: 2026-09-24. Scope: commit 6029aeb ("1.0.1: close the review's correctness findings"),
21 files, against the same ground rules. Read-only; nothing in the repository was modified.

What was run:

- `app/build.sh` (passes; about 37 distinct warnings, up from about 30), `app/test.sh`
  (450/450, 28 new tests), the known-answer suite (20/20)
- `Tests/crash_test.sh`, 3 kills and 1 round, from two spellings of the same scratch
  directory: **passes from `/tmp/...`, fails 6 checks from `/private/tmp/...`**. Both were
  green on 1.0.0.
- The round-one experiments repeated on the new binary (exp1, exp2, exp3, exp5), plus new
  ones: a keeper change under both path spellings (exp A), a source rename and rescan
  (exp B), a date-range place rule against a copy-dated file, a `standardizedFileURL` probe,
  and a Takeout-style folder with `.json`, `.aae` and `.xmp` companions.

Every finding is marked **VERIFIED** or **SUSPECTED** as before. New findings are numbered
R1–R13; round-one findings keep their numbers.

---

## 1. Project summary

Unchanged in shape from round one. The 1.0.1 commit adds `CHANGELOG.md`, an `Act.retire`
step that removes a superseded kept copy from the clean library, AUTOINCREMENT on newly
created catalogs, capture-instant, shape and blank-frame guards on tier B, an
`unreliableTime` gate on same-day and neighbour inference in the resolver, a catalog
recovery screen, off-main-thread Tidy and Undo with streamed hashing, per-source
"unrecognised" counts, a "Keep the clock" correction beside "Correct", XMP-only tags for
GIF and WebP, RAW extensions preserved, root standardisation in `Act.run`, spherical
centres, local-zone display of file dates, and rewritten install docs.

---

## 2. Top 5 issues

1. **Finding 1 is not closed in effect.** Tier B now refuses to join two black frames from
   different days, but tier C joins each of them to an undated blank GIF, and union-find
   chains them together anyway. exp1 still produces one "same image" group of `black1`,
   `black2` and the GIF. Blank frames also generate "edited copy" review pairs against every
   other flat frame.
2. **The trailing-slash fix introduced an unstable manifest key.** `Act.run` standardises
   the root with `standardizedFileURL`, which strips `/private` only when the path already
   exists. The first write therefore stores one root and every later write another. In that
   state `prepare` discards every verified row, the whole library is rewritten as `_2`, and
   Undo removes nothing. The project's own crash suite fails with 147 orphan files when run
   from `/private/tmp`.
3. **`Act.retire` orphans files after a source rename or rescan.** A verified row whose file
   id or path changed is deleted outright while its file stays on disk. The photo is written
   again as `_2`, and Undo can no longer remove the first copy. In 1.0.0 the stale row at
   least kept Undo able to clean up.
4. **Copy-dated files still receive places through date-range rules, and those places are
   written.** `unreliableTime` gates same-day and neighbour inference but not rule
   matching. A "2020" rule placed an mtime-only file at 51.5, -0.12 and Act wrote it into
   the clean copy.
5. **The "not recognised" count includes Takeout sidecars.** `.json`, `.aae` and `.xmp`
   are counted as "not photos or videos the app reads", so a Google Takeout export will
   show thousands of alarming leftovers on the primary use case, although the sidecars were
   read as evidence.

---

## 3. Findings table

Open items only, sorted by severity. Closed items follow the table with how each was
verified.

| # | Severity | Category | Location | Problem | Why it matters | Suggested fix | Effort | Verified? |
|---|---|---|---|---|---|---|---|---|
| R1 | Critical | Correctness | `app/Sources/Clusterer.swift`, tier C candidate loop; `sameShape` and `featureless` are called only from tier B | Tier C has no shape or blank-frame guard. Pair table from exp1 at radius 4: `black1–gif merged`, `gif–black2 merged`, `black1–black2 burst`. Union-find joins all three; the cluster method still reads "same image". Blank frames also yield `variant` pairs against a solid blue PNG. | The one unrecoverable outcome remains reachable through an undated blank frame; the review queue fills with meaningless pairs. | Apply `sameShape` and `featureless` in tier C before `verify`; treat a featureless pair as unverifiable unless the capture instants match; add a test with an undated blank frame between two dated ones at radius 4. | S | VERIFIED (exp1 pair table) |
| R2 | High | Correctness / Resilience | `Act.swift` `run` (root standardisation), `prepare` root filter; `Engine.swift:585, 651` | `standardizedFileURL` strips `/private` only if the path exists (probe: `<SCR>/std/exists → /tmp/...`, `<SCR>/std/does-not-exist-yet → /private/tmp/...`). The stored `output.root` differs between the first and later writes under `/private/tmp`, `/private/var`, `/private/etc`. `prepare` then deletes every verified row, everything is rewritten as `_2`, and `Act.undo` and `writtenCount` still use the raw root and match nothing. Crash suite: "147 files on disk the manifest does not know", "451 files left after undo", "304 manifest rows left after undo". | The resumable-manifest safety mechanism silently fails for any affected destination, and the regression suite now depends on where it is run. Exposure through NSOpenPanel is low; the key must still be stable. | Standardise once, in one place (`Engine.chooseDestination` or an `Act.canonicalRoot`), with a function that does not depend on filesystem state, and use that value wherever `output.root` is written or compared. Run the crash suite from a `/private` path. | S | VERIFIED (probe + crash suite) |
| R3 | High | Correctness | `Act.swift` `retire`, first `DELETE` | Rows whose file id or path no longer matches are dropped without touching their file. After a source rename and rescan (exp B, stable root) the photo is written again as `_2`; Undo removed 1 of 2 and left the first copy. | Orphaned copies in the "clean" library that the app can no longer account for. Worse than 1.0.0 for Undo. | Before dropping a row, re-attach it to the file that now carries the same sha256, or remove the written file if it still matches `written_sha`; only then delete. | M | VERIFIED (exp B) |
| R4 | Medium | Correctness | `Resolver.swift` step 2c (rules loop has no `unreliableTime` gate); `Act.tags` `placeRead` includes `your rule:` | A date-range rule matches the copy date of an mtime-only file and the resulting GPS is written. Driver + `actc`: `noexif.jpg` → `your rule: test rule`, written GPS 51.5, -0.12. | Same class as finding 2: invented GPS in a file whose only date is a copy date. | Skip day-range rule matching when `unreliableTime`; folder rules may stay, they do not depend on the date. | S | VERIFIED |
| R5 | Medium | UX | `Ingest.swift` unrecognised counting; `Views.swift` SourceCard help text | Every file the sniff rejects counts, including `.json` sidecars, `.aae`, `.xmp`. exp1: "json ×2, avi ×1, aae ×1, xmp ×1". A Takeout export will report roughly one "not a photo or video" per photo. | The new warning cries wolf on the primary use case and buries the real AVI/MKV signal. | Exclude known companion files (json, aae, xmp, txt, ini, db) from the count, or list them separately as "sidecars read". | S | VERIFIED (exp1) |
| R6 | Medium | Correctness | `Engine.removeAll` (now wipes `output`); `Act.prepare` | After Clear and re-add, a write to the same destination has no manifest and writes every file again as `_2`. Rerunning `known` into an existing folder produced 13 files for 6 photos. | Clear is presented as a safe reset; combined with a reused destination it doubles the library. | Keep a copy of the manifest in the destination root and reconcile against it, or refuse a non-empty destination the manifest does not know. | M | VERIFIED (exp1 rerun) |
| R7 | Medium | Correctness | `Catalog.swift:39` (`CREATE TABLE IF NOT EXISTS`) | AUTOINCREMENT applies only to catalogs created by 1.0.1. Every 1.0.0 catalog keeps `INTEGER PRIMARY KEY` and reuses ids (`sqlite_master` of a 1.0.0 catalog confirms). Mitigated by the path checks in `retire` and `Tidy.plan`. | The changelog says so, but the fix does not reach existing users. | Rebuild `file` with AUTOINCREMENT in `migrate` (copy, drop, rename) inside one transaction, behind a schema version row. | M | VERIFIED |
| R8 | Medium | Regression risk | `Act.tags` `xmpOnly` includes `image/webp` | WebP can carry EXIF and did in 1.0.0 (round-one exp3 read back `DateTimeOriginal`). It now gets XMP only. Whether Photos and ImageIO read XMP dates from WebP is unconfirmed; `sips` reports no creation date for either variant, `mdimport -t` printed nothing. | A date Photos ignores is a date lost on import. | Keep EXIF for WebP; XMP-only for GIF alone. Confirm by importing one written WebP into Photos. | S | SUSPECTED |
| R9 | Medium | Concurrency | `Engine.swift` detached readers on the one connection | Unchanged from finding 14; acknowledged in the changelog. | Transient wrong numbers during a regroup. | Read-only connection for the UI. | M | SUSPECTED |
| R10 | Low | Docs accuracy | `CHANGELOG.md`; `app/test.sh:5, 26` | Changelog: "build and test scripts find Xcode via xcode-select"; `test.sh` still hardcodes `/Applications/Xcode.app` and the miniforge python. "Icon-only buttons have VoiceOver labels": two of three (the tip-banner close button in `HelpView.swift:189` has none). | A changelog that overstates fixes erodes the trust the docs work hard for. | Fix `test.sh` or correct the changelog; label the close button. | S | VERIFIED |
| R11 | Low | Code quality | `Engine.swift` `perform`, `performSecondary`, `cards`; `Guide.Card` action strings; `Sniff.Kind.other` | No callers for the card actions; `Kind.other` still never produced. The "Correct all" primary action from finding 13 exists only in this dead code. | Misleads the next reader about what the UI does. | Delete or wire up. | S | VERIFIED (grep) |
| R12 | Low | Build | build log | Distinct warnings rose from about 30 to about 37 (new detached tasks capture `self`); deprecated AVFoundation calls unchanged. Acknowledged. | Same as finding 19. | Same as finding 19. | M | VERIFIED |
| R13 | Low | Correctness | `Engine.putBack`, `Engine.undoWrite` guards on `task == nil` | While the rescan started by Tidy is still running, ⌘Z on "Move duplicates to the Trash" silently does nothing. Pre-existing. | Undo appears broken for a few seconds after Tidy. | Queue the undo behind the running task, as `restore` already does. | S | VERIFIED (trace) |
| — | — | Open from round one, unchanged | 14, 16 (partial: denied folders detected, Photos path still constructed, no usage string), 17 (partial: gazetteer only), 19, 20, 23, 24, 29, 32 | See the round-one table above. | | | | |

### Closed since round one, and how it was checked

- **2** (same-day and neighbour inference from copy dates): `noexif.jpg` resolves with no
  place and no zone; the written copy carries no GPS. VERIFIED exp1. Gap remains for rules,
  see R4.
- **3** (manifest follows a keeper change): one file, no `_2`, under a stable root.
  VERIFIED exp A. Fails under an unstable root, see R2; orphans on rename, see R3.
- **5** (silent skips): AVI counted on the source card. VERIFIED exp1. Noise, see R5.
- **6** (RAW extension): `Undated/shot.nef`. VERIFIED exp1.
- **7** (launch crash): guarded; recovery view with "Put it aside and start again".
  VERIFIED by trace.
- **8** (main-thread file work): Tidy, put back and undo run detached with progress;
  streamed hashing; kept copy hashed once per group. VERIFIED by trace.
- **9** (install docs): Sequoia path documented. VERIFIED docs.
- **10** (GIF): written with XMP dates, no failure. VERIFIED exp3.
- **11** (nested Photos library): package skipped when the source is its parent. VERIFIED
  exp1.
- **12** (write settings in the undo snapshot), **30** (snapshot errors), **31**
  (antimeridian), **21** (file date shown in local time), **18** (300 of N), **27** (doc
  numbers), **28** (Intel labelled), **22** (trailing slash, in `run` only — see R2), **25**
  partly (`hasColumn` and `tierC += 0` removed). VERIFIED by diff and tests.
- **13** (correction model): "Keep the clock" added beside "Correct" in the checks
  section, with text explaining the two readings. VERIFIED by diff. Risk reduced, not
  removed.

---

## 4. Quick wins

- Add `sameShape` and `featureless` to the tier C candidate loop before `verify`. Closes R1.
- Standardise the destination once, in `chooseDestination`, with a function that does not
  depend on whether the path exists, and use that string in `run`, `undo`, `space`,
  `check`, `retire` and `writtenCount`. Closes R2.
- Gate day-range rules on `!unreliableTime`. Closes R4.
- Exclude sidecar extensions from the unrecognised count. Closes R5.
- Restore EXIF for WebP. Closes R8.
- Fix the `test.sh` paths and the two changelog sentences; label the tip-banner close
  button. Closes R10.
- Delete `perform`, `performSecondary`, `cards` and `Kind.other`, or use them. Closes R11.

---

## 5. Structural concerns

- **The manifest is keyed on a string.** R2 and R3 both come from `output` rows being
  identified by `(root text, file_id)`. Key rows by the source file's sha256 plus a
  normalised root, and treat `file_id` as a cache. A rescan then re-attaches rows instead of
  orphaning them, and the root is compared as one normalised value in one place.
- **Guards live in one tier.** The burst, shape and blank-frame guards now exist as
  functions but are consulted by tier B only. Put them in one `compatible(a, b)` predicate
  that every tier calls, and test the transitive case explicitly.
- **The crash suite should run from more than one path.** It caught R2 immediately once run
  from `/private/tmp`. Add a second scratch location to `crash_test.sh`, and run it before
  each release.
- Round-one concerns still stand: a read-only connection for the UI, one error channel,
  notarization.

---

## 6. What could not be assessed

- As in round one: the running UI, Gatekeeper on a clean machine, TCC behaviour, the Intel
  slice, behaviour at 100k+ files.
- WebP XMP readability in Photos (R8): `mdimport` and `sips` gave no answer either way.
- Whether NSOpenPanel can return a `/private/...` or otherwise symlinked destination on a
  real machine. If not, R2's user exposure is limited to the crash suite and to anyone
  scripting the engine; the fix is still warranted because the manifest key must not depend
  on filesystem state.

---

## Appendix — round-two experiment details

**exp1 rerun** — same library as round one plus `A.jpg.supplemental-metadata.json`,
`B.jpg.supplemental-metadata.json`, `A.xmp`, `IMG_0001.AAE`. Results: 8 files scanned
(AVI and companions counted as "json ×2, avi ×1, aae ×1, xmp ×1"); nested library skipped;
`black1`, `black2` and the GIF still one cluster via tier C (`pair` outcomes above);
`noexif.jpg` with no place or zone and no GPS in its written copy; `shot.NEF` written as
`Undated/shot.nef`. Rerunning into the existing `out` folder without clearing it produced
`_2` copies of every file (R6).

**Rule test** — a headless driver compiled from the engine sources added a place rule for
2020-01-01…2020-12-31 at 51.5, -0.12 and regrouped exp1's catalog. `noexif.jpg` resolved to
`your rule: test rule`; `actc` into a fresh folder wrote GPS 51.5, -0.12 into
`Undated/noexif.jpg` (R4).

**exp A** — `prep` + `actc` on one photo with a byte-identical backup, roles swapped in
`member`, `actc` again. From `/private/tmp/...`: `already 0`, old file kept, `_2` written.
From `/tmp/...`: one file, no `_2` (finding 3 closed under a stable root).

**exp B** — as exp A, then `A.jpg` renamed on disk and in the catalog with a new id (as a
rescan does), `actc`, `undoc`. Result: `_2` written; undo removed 1 of 2; the first copy
left on disk (R3).

**exp5 rerun** — `actc` with a trailing-slash root: `output.root` now stored standardised;
`undoc` with the same trailing-slash spelling removed 0 (R2, raw root in `undo`).

**Standardisation probe** — a two-line Swift program printing
`URL(fileURLWithPath:).standardizedFileURL.path`: an existing `/private/tmp/...` path came
back as `/tmp/...`, a not-yet-existing sibling kept `/private` (R2).

**Crash suite** — `Tests/crash_test.sh <dir> 3 1` from `/private/tmp/...`: 6 checks fail
(147 orphans, undo removes 0). From `/tmp/...`: all pass (R2).

**exp3 rerun** — GIF and WebP both written; `exiftool -G1 -a` shows `XMP-exif:DateTimeOriginal`
and `XMP-xmp:CreateDate` only, no EXIF, on both (10 closed; R8).
