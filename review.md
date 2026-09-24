# PhotoMerge 1.0.0 — pre-release code review

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
