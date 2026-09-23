# PhotoMerge.app

<img src="Resources/AppIcon-1024.png" width="96" align="right" alt="">

A macOS app that tidies a photo collection scattered across folders, drives, Google
Takeout exports and the Photos library: it finds the duplicates and keeps the best copy
of each, works out when and where every photo was taken, and saves a clean library — one
file per photo, dates, time zones and places written in. **Entirely offline.** Your
originals are never modified; every choice can be undone.

## Build

```sh
brew install exiftool   # bundled into the app at build time
./build.sh              # → build/PhotoMerge.app
./test.sh               # the engine tests, headless
```

Requires macOS 14+, and **Xcode installed with its licence accepted**
(`sudo xcodebuild -license accept`). There is no Xcode project; `build.sh` calls `swiftc`
directly — but SwiftUI's `@State` is a macro whose plugin ships only with Xcode
(`docs/SPIKES.md` §4).

## Use

**The guided view** (the default) is one flow, four steps across the top of the window:

1. **Add photos** — drag folders in, choose them, or add the Photos library in one click.
   Reading starts at once; results appear as it goes.
2. **Duplicates** — every photo with more than one copy, the copy kept and why; the
   matching setting, tried on the collection before it is applied; edited copies put to you.
   The kept copy takes its date, zone and place from all its copies together.
3. **Time & place** — *Worked out for you* (coverage; places worked out, gathered by 50 km
   area with *Accept all* per area; times that contradict their place; days whose zone is
   unclear; how far a photo may borrow a place) or *Fill in by hand* (a grid of what is
   still missing or worked out, filled many at once — a place you enter replaces a
   worked-out one, so fix the odd ones out first, then accept the rest). Steps 2 and 3 can be taken in
   either order and revisited; Save opens once every photo has a date and a place, or
   you choose to leave the rest as they are.
4. **Save** — *Save a clean library* (a new, verified copy) or *Tidy in place* (extra
   copies to the Trash, restorable).

⌘Z undoes any choice, app-wide; Help (⌘?) is built in and offline. **View → Advanced
Tools** (⌥⌘A) shows every pane below.

### Advanced tools

1. **Sources** → *Add folder…* → *Analyse*
2. **Duplicates** → groups, largest recoverable first; **To review** → edits of one shot
   (a crop, a filter, an exposure change) that the app will not merge without you
3. **Dates & places** → coverage, and any day whose timezone is still open
4. **Decisions** → any photograph, and how each fact about it was decided
5. **Dials** → every threshold, previewed on your photographs before it is applied

⌘1–⌘8 move between panes; ⌘R analyses (resuming if interrupted), ⌘. stops; ⌘E exports every photograph's findings as CSV or JSON.
The export, written only where you choose, is the one file PhotoMerge writes outside
its own catalog. Your photographs are never touched.

Every choice you make — a timezone for a day, a verdict on a pair — is stored in the
catalog, shown as *yours*, and can be taken back from the same place. Verdicts on pairs
are keyed by content hash, so they survive a rescan that renumbers every file.

## Dev tools

```sh
./test.sh                                  # unit + real-file tests
./test.sh <folder>                         # also runs tests against real files
./test.sh analyse <folder> [radius]        # full pipeline into the app's catalog
./test.sh sweep <folder> [limit]           # radius dial's effect on this collection
./test.sh backtest [catalog]               # score the timezone ballot against known days
./test.sh backtest <catalog> sweep         # compare daylight-signal shapes
./test.sh regroup [radius]                 # regroup + resolve the app's catalog, no rescan
./test.sh preview                          # time the dial previews on the app's catalog
./test.sh resume                           # scan + read what is unread + group + resolve, as ⌘R does
```

Two end-to-end checks, both on synthetic libraries drawn by the scripts (no real photos):

```sh
Tests/known_library.py /tmp/k/lib                        # 42 files, 19 cases with known answers
./build/tests known /tmp/k/lib /tmp/k/cat.sqlite /tmp/k/out
Tests/check_known.py /tmp/k/lib /tmp/k/cat.sqlite /tmp/k/out   # PASS/FAIL per case
Tests/crash_test.sh /tmp/crash [kills] [rounds]          # kill -9 the writer, Undo and Tidy; resume; check
```

*Known answers* covers copies, re-encodes, bursts, edits, Takeout sidecars (both collision
conventions, edits, `(0,0)`), clock + instant, Pixel and `IMG_` names, undated files, a
wrong zone, same-day and same-folder places, Live Photo pairing and a mislabelled HEIC, and
reads the written files back. *Crash* kills processes at random and, through `PM_CRASH=<point>:<n>`,
exactly at each commit point, then checks every photo is written once and verified, nothing
half-written or unknown to Undo is left, every trashed duplicate can be restored, and no
original changed.

`Tools/click.py win X Y` clicks at a point relative to the app's window (a screenshot
pixel ÷ 2 on Retina), and `Tools/wid` prints its window id for `screencapture -l`.
Between them the UI can be driven and photographed from a script — SwiftUI exposes almost
nothing to AppleScript, and System Events' own `click at` times out against this app.
Launch with `open --env PM_DEBUG=1 --stderr /tmp/pm.log build/PhotoMerge.app` for
diagnostics.

Driving it from a script failed in four distinct ways, each of which looked like an app
bug: the window reopening elsewhere (remembered coordinates hit the wrong control), a
first click that only activates the window, `NSSegmentedControl` ignoring mouse events
with no click count, and clicks that intermittently never arrive. **Check the effect in
the catalog, not only on screen** — `sqlite3` against the catalog is the ground truth.

`sweep` is how the radius default was chosen. It prints the number that matters:

```
radius  groups   duplicates   recoverable   longest chain
0       2000     0            Zero KB       1
4       1995     5            7.8 MB        2
8       1993     7            12.4 MB       2
```

A chain that stays flat as the radius widens means verification is doing its job. If it
climbs, something has stopped checking candidates — see below.

## The timezone ballot, and what it actually scores

When a whole day has no zone, the app scores every real offset by independent local
signals and offers the top three with their evidence. A pick is stored by day, applied
before any inference so it reaches neighbouring days, credited as *"you chose it"*, and
reversible from the same pane.

`./test.sh backtest` hides the zone on days that have one and re-derives it. On the
10,913-file reference library, 1,354 scorable days:

```
committed to an answer   322  (23.8% of days scored)
…and was right           312  (96.9% of those)
right answer offered    1287  (95.1%)
confidently wrong         10  (0.7%)
signals that spoke: Neighbouring day 100%  Daylight 32%  This camera 85%
                    Time of day 0%  Filename 0%
```

Three things that cost real time here:

1. **The first run scored 84% with a signal structurally absent.** The catalog predated
   the `ev` column, so every exposure value was NULL and the daylight signal never spoke.
   The back-test now prints per-signal participation: a signal silent *everywhere* means
   missing data, not agreement.
2. **The daylight curve was worse than nothing as a ranking signal** — 66.8% against
   86.5% without it, every error positive, because the centre of a day's photography is
   hours after the centre of its daylight. It ships as a wide veto instead, which halves
   how often the ballot is confidently wrong.
3. **Two identical runs scored differently** (84.0%, 84.9%). Dictionary iteration order
   was reaching the tie-breaks — nearest-zoned-day, per-day offset, and Swift's
   non-stable `sort`. All three are now explicit.

The gate was also wrong as first written: *"top pick right ≥90%"* marks an honest *"cannot
separate +08:00 from +09:00"* as harshly as picking the wrong continent. See PLAN §11.

## One pipeline

`Sources/Pipeline.swift` holds the grouping and resolving stages, and it is the only code
that writes `cluster`, `member`, `pair` or `resolution`. The app's Engine and the test
harness both call it.

That exists because for a while they didn't. The app's *Analyse* button ran its own copy
of tier C — no pixel verification, no burst guard, no video tier — while every test and
every measurement in this README ran `Clusterer`. The suite was green, the numbers were
right, and the shipped button would have merged the 117 unrelated photographs the guards
below were built to stop. `testPipeline` now runs the stages the app runs, against a real
SQLite catalog.

The same week, `test.sh` was found reporting **155/155 passed on code that did not
compile**: `swiftc … | grep error: && exit` never fires under `pipefail`, so a failed
build quietly re-ran the previous binary. It now deletes the binary first, checks the
compiler's own exit status, and compiles every engine file by exclusion rather than by
list, so a new file is tested by default.

## Boundary cases

Tier C records every candidate it considers and what became of it. A pair that shares a
capture instant and a frame but differs evenly — an edit — is **never** merged
automatically; it goes to *To review*. On the reference library that queue holds 11
pairs at the default radius: crops, filters and exposure changes, every one sharing a
capture second with its partner. The largest difference (47 on a 0–255 scale) is a crop
plus an exposure change, which is why there is no cap on how different a variant may be:
the evidence did not support one.

## Dials, previewed

Each dial shows what it would do before it is applied: the radius table re-runs the
cascade at every setting (1.2 s for five on 10,268 stills), and the place dials re-run the
resolver on every slider move (0.08 s). Samples come with both, ranked so the calls most
likely to be wrong are first.

The samples earn their place. Widening *Borrow a nearby fix* from 60 to 240 minutes gains
20 places on the reference library — and the samples show they are almost all photographs
out of an aeroplane window, pinned to an airport a fix was taken at hours earlier. The
count alone looks like an improvement.

## Export

One record per photograph: kept path, duplicate paths, local time, offset, UTC instant,
place, and the provenance of each. `instant_utc` is empty whenever the zone is unknown —
a wall clock without a zone is not an instant. Paths that begin with `= + - @` are
defused against spreadsheet formula injection; offsets and coordinates are not. The first
version defused everything and turned **8,456 of 10,907** offsets into `'-07:00`, which no
unit test caught and one look at the real file did.

## Reading, resumably

`Sources/Ingest.swift` finds and reads files for both the app and the tests. Every
batch is committed as it is read, so quitting — or `kill -9` — loses at most one batch
per worker; ⌘R reads only what is left. Groups are rebuilt every few seconds while it
runs, so the first duplicates appear long before the last file is read. Measured on the
reference library: stopped at 5,512 of 10,913, quit, relaunched, resumed in 43 s instead
of 80, with an identical result; killed with `kill -9` mid-run, the catalog passed
`integrity_check` with no half-written row.

A file that cannot be opened is marked failed, not retried forever. A file that changes
is read again; one that disappears is forgotten — but only after a walk that finished,
and never when the whole source is missing (an unplugged drive is not an empty folder).

## Evidence from outside the file

- **Takeout sidecars** (`Sources/Sidecar.swift`), ported from the CLI's cascade: both
  `(n)` collision conventions, case-folded lookup, edits inheriting from their origin.
  All 12,355 sidecars in the workspace export parse.
- **Filenames** (`Sources/Names.swift`). Whether a name is a wall clock or a UTC instant
  is measured, not assumed: against 4,320 sidecars that record the true instant, 3,393
  of 3,395 Pixel names (`PXL_…`) matched **UTC**, while `IMG_…` names sat at −7, −8,
  +8 h from it. The Python CLI read Pixel names as local.
- **A wall clock plus an instant is a timezone.** When a photo records its local clock
  and a sidecar, container or filename records the same moment absolutely, the offset
  is their difference — read, not inferred.
- **An instant with no clock is never given an invented zone.** It borrows one from where
  it was taken, or from the nearest photograph in time within two days; failing both it
  is shown in UTC and says so, and its ordering is still exact.
- **Folders** name a place only when the photographs in them that do carry GPS agree
  (same 25 km radius as same-day) — so a folder named for one park does, and one named
  for a whole country does not.
  Storage folders (`0`…`F` shards, `DCIM/100APPLE`, date folders) are never albums.

Found on the way: **every video's time was wrong by its timezone.** QuickTime's creation
date is UTC by specification, and it was being stored as a local clock. On the reference
library all 641 videos moved by exactly their offset (−5 h ×228, −6 h ×189, +8 h ×78…),
and the count of timezones read straight off files rose from 10,261 to 10,902, because
Apple's own local-with-offset date is now read first.

## Live Photos

A still and its clip are one photograph. `Sources/Companions.swift` pairs them by Apple's
`ContentIdentifier`, keeps **at most one** companion per still, and allows a name match
only when the movie has no identifier of its own and is under 6 s (BUILDLOG §2.11: a 36 s
video sharing a name once took the real clip's place). On the reference library 271 pairs
join, and the asset count reconciles with Apple Photos' own database exactly:

```
10,913 files = 10,637 Photos assets + 271 Live Photo clips + 5 files Photos no longer references
app assets   = 10,913 − 271 clips − 6 duplicates = 10,636
```

## Choosing the copy, and comparing

In a group, *Keep this copy instead* (or the number keys 1–9) overrides the app's choice;
it is stored by content hash, so it survives regrouping and rescans, and *Let the app
choose* takes it back. Space opens **Compare**: two copies at the same size, side by side
or flipped in one frame — flipping is how a crop, colour or sharpness difference actually
becomes visible.

## A merged copy

The *Merged copy* pane writes a new, clean library: one file per photograph, named
`YYYY/MM/YYYYMMDD_HHMMSS.ext`, Live Photo clips beside their stills, duplicates left out,
and the dates, offsets and places worked out here written into each file — the full
capture-date set, so no reader finds a stale date that outranks EXIF. Originals are never
touched. Every file is:

1. copied under a temporary name that keeps its real extension (AVFoundation identifies a
   container by it — with the marker last, every video failed verification);
2. tagged by the bundled exiftool (`-stay_open`; `-q` is never used, because it also
   suppresses the `{ready}` marker the protocol waits for);
3. **read back and verified** against its original by the same identity the grouping
   uses — decoded pixels for a still, duration and sampled frames for a video;
4. renamed into place, never over an existing file.

The manifest (`output`) is written as it goes, so a run can be stopped or crash and
resume. Each file is marked *committing*, with its final name and hash, before it is
renamed into place, and the next run (or Undo) recognises a committed file by that hash:
the crash test found that a kill in that instant — wider than it sounds, with eight writers
queueing for the catalog — left the photo written twice, the first copy unknown to Undo. *Undo* removes only files still byte-for-byte as written; anything you have edited
since is left alone. The write is refused up front when the destination is inside a
source, contains one, or lacks space — measured conservatively, since a long write should
not depend on macOS purging space in time. On the reference library a full copy needs
about 48 GB, so it is refused on the internal disk and needs an external drive.

Checked independently with exiftool on a real sample (6 Live Photos, 4 videos, HEICs and
a duplicate pair, 37 files): 35 written, 0 failed; both halves of each Live Photo keep
their shared `ContentIdentifier`, so Photos re-pairs them on import; video `CreateDate` is
UTC and `Keys:CreationDate` local with offset; the sample stayed 37/37 identical to the
library.

## Checks: contradictions in the result

`Sources/Audit.swift` looks for timezones that cannot both be right:

- two photographs within half an hour and 50 km of each other with different offsets;
- a photograph *measured* within 25 km of a town whose clocks showed another offset at
  that instant — the town's IANA zone comes from GeoNames, the offset from the system's
  own tz database, so daylight saving and historical changes are the town's, not a guess;
- where no town is near, one whose offset every photograph taken there that month disputes.

When two photographs disagree, the town's clock decides which is wrong; only where no
town is near do the photographs around them outvote each other, and an even split is put
to you. A majority alone is not trusted, because whole sessions go wrong together: a
camera left on home time tags forty photographs in a row. The known-answer test found
this — the first rule used to blame whichever photograph was taken first.

On the reference library the audit finds **547**, every one an offset *stored in the
file* — none from the app's own inference. Most are cameras with no GPS or zone of their
own left on another continent's time for a whole trip, which the pairwise rule could not
see because nothing in the session disagreed; the rest are a correct instant written under
the offset of the computer that ran an earlier merge. *Correct* keeps the instant and
fixes the offset, by content hash; nothing is written to your files until a merged copy
is made. A zone you set yourself is never flagged.

## Timeline, exclusions and place rules

- **Over time** — photographs per month, split by how each time was known (read, worked
  out, no zone). Blue and orange are validated for colour-vision deficiency in both
  modes; grey is absence, not a category.
- **Exclusions** per source: a name skips that folder or file anywhere ("Screenshots"), a
  pattern matches names or paths ("*.png", "sub/*"). Files already read that now match are
  forgotten by the next scan; an excluded folder is never walked.
- **Place rules** ("that whole year I lived in one city", BUILDLOG §2.18): made from any located
  photograph in Decisions, for its folder or a range of days. They apply last, only to
  photographs no evidence could place, a folder rule before a date rule.

## Fill in, by hand and in bulk

The *Fill in* pane gathers every photograph with no date (or only a file date) or no
place, sorted by time so a trip's photographs sit together. Select as in Finder — click,
⌘-click, ⇧-click for a range, or drag a box across the grid (⌘/⇧ while dragging adds) —
then give them all a **day** and/or a **latitude, longitude** (decimal, hemispheres, or
degrees-minutes-seconds; recent places one click away). Entries are stored by content
hash, credited as *you entered it*, and cleared from the same pane. They fill only what is
missing: a date or GPS a file records is never replaced, while a file-date guess or a
worked-out place is. A day has no time, so a merged copy writes it as noon; an entered
place also lets the timezone be looked up from photographs taken nearby.

## Tidy in place

Moves extra copies to the Trash, recorded so they can be put back (⌘Z, or *Put them all
back*). A copy is moved only if the one being kept still exists with the content the
grouping saw, and only if it is itself unchanged — the last copy of a photograph is never
moved. Nothing inside a `.photoslibrary` package is touched: moving files out of a Photos
library's `originals/` damages the library, so on the reference library Tidy refuses and
points to *Save a clean library*. Each move is recorded before it is made; after a crash,
a copy that never left is forgotten and one that did is found in the Trash by its size and
hash, so it can still be put back.

## Undo

Every choice lives in a handful of small catalog tables (time zone picks, pair verdicts,
kept copies, corrections, entries, rules, settings, exclusions). Before an action the app
snapshots them; ⌘Z restores the snapshot and rebuilds groups and resolutions from it, and
redo falls out of the same mechanism. While a text field is being edited, ⌘Z stays the
field's own.

## Place names, offline

`Resources/places.tsv` — 34,148 cities of 15,000+ people from GeoNames (CC BY 4.0), with
their Chinese, Japanese and Korean names and IANA time zone, built by
`Tools/make_places.py`. Coordinates read as a town and country ("Lisbon, Portugal")
within 15 km, "near …" within 60 km, or stay coordinates further out — deep in a national
park the nearest such town can be over 100 km away, and a far town's name would mislead.
*Fill in* accepts a city name ("Lisbon", "東京") as well as coordinates. The time zone
gives the audit the civil offset at a place and instant, from the system's own tz
database. Nothing is looked up online.

## Found while building it

- **A saved window state with no window open relaunched the app to a bare menu bar.**
  SwiftUI restores its own scene state whatever the app delegate says; registering
  `ApplePersistenceIgnoreState` is the switch both honour.
- **A Help window hosted in AppKit came up 2×2 points** — `NSHostingController` sizes its
  window to the content's ideal size unless told not to.
- **Blank screenshots were a locked screen**, not a broken view: capture returns empty
  images while the display sleeps. One view was rewritten before that was noticed.

## Open

- **Edits made inside Apple Photos.** The app reads `originals/`, so a merged copy has the
  unedited version. On the reference library that is 2 photographs of 10,637. The proper
  source is PhotoKit, which needs the user's permission once — not yet run (SPIKES §2).
- **Google motion photos** are detected and copied, but not remuxed into Live Photos:
  that needs ffmpeg with an explicit stream map (BUILDLOG §2.3) and Apple's MakerNotes
  identifier, which exiftool cannot create (§2.4).
- **5 files inside the reference Photos library are no longer referenced by Photos** —
  real photographs, invisible in the app that owns the folder. Reported, not touched.

## The three guards

Tier C finds *candidates* by perceptual distance. Distance alone is not enough:

1. **Separation** — copies of one photograph share a capture instant; burst frames do
   not. Without this, 9 frames shot over 9 minutes merged into one group.
2. **Pixel verification** — compared at 64×64 *and* 16×16. A difference that stays flat as
   detail is added is one frame (under 4: a re-save, merged; above: an edit, put to you);
   one that rises is two photographs. Without any check, radius 4 merged **117 unrelated
   photographs spanning 2016–2026**, because A~B and B~C chains A to C transitively. A
   single 16×16 check was not enough either: it passed nine pairs of different photographs.
3. **Best copy** — most pixels, then largest file, then a deterministic tiebreak.

Both failures above are real, were found by testing on a 10,913-file library, and have
named regression tests in `Tests/main.swift`.

## Layout

```
Sources/Catalog.swift     SQLite, WAL, one writer, additive migrations
Sources/Sniff.swift       magic-byte typing; ftyp brands split HEIC from MP4
Sources/Extract.swift     sha256 + dhash + 64×64 thumb + EXIF/GPS + EV, one decode
Sources/VideoExtract.swift  duration + sampled frame hashes via AVFoundation
Sources/BKTree.swift      BK-tree + union-find
Sources/Clusterer.swift   the cascade, pure and testable
Sources/Resolver.swift    time, place, zone; and the ballot's day index
Sources/Ballot.swift      five timezone signals, and first-class refusals
Sources/Pipeline.swift    the grouping and resolving stages — the only writer of results
Sources/Decisions.swift   the chain behind any asset, as plain sentences
Sources/Preview.swift     what a dial would do, computed without writing
Sources/Export.swift      CSV (RFC 4180) and JSON
Sources/Format.swift      shared formatting, and PM_DEBUG logging
Sources/Ingest.swift      scan and read, resumably, for the app and the tests alike
Sources/Sidecar.swift     Google Takeout sidecars
Sources/Names.swift       dates in filenames (wall clock or UTC), folders as places
Sources/Companions.swift  Live Photo and motion-photo pairing
Sources/Act.swift         the merged copy: plan, write, verify, commit, undo
Sources/ExifTool.swift    the bundled exiftool, stay-open
Sources/Engine.swift      orchestration, parallel to performance cores
Sources/Design.swift      the visual language: spacing, metrics, cards, pills
Sources/App.swift         app, sidebar, scoreboard, progress, ⌘1–⌘5, ⌘E
Sources/Views.swift       Sources, Duplicates, To review, Dates & places, thumbnails
Sources/DecisionsView.swift  the Decisions pane
Sources/DialsView.swift   the Dials pane
Sources/WriteView.swift   the clean-library pane
Sources/Guide.swift       the guided path's steps and attention cards, as a testable model
Sources/GuidedView.swift  Add photos → Duplicates → Time & place → Save
Sources/Tidy.swift        tidy in place: to the Trash and back, with its safety rules
Sources/TidyView.swift    its pane
Sources/Gazetteer.swift   place names, offline
Sources/Manual.swift      dates and places entered by hand, and Finder-style selection
Sources/FillView.swift    the Fill in pane
Sources/HelpView.swift    Help, the welcome sheet, one-time tips
Resources/                places.tsv (GeoNames), AppIcon.icns (Tools/make_icon.swift)
Tests/                    399 tests + headless integration + ballot back-test
Tools/wid.swift           window id, for screencapture -l
Tools/click.py            window-relative synthetic clicks, for driving the UI
```

## Thumbnails, and three failed attempts at them

Worth reading before changing `Thumbnails` in `Views.swift`, because each simpler
version was tried and removed:

1. **QuickLook** (`QLThumbnailGenerator`) silently produced nothing for most rows.
   Requesting only `.thumbnail` fails when it cannot make a high-quality one quickly,
   and that failure is indistinguishable from "still loading".
2. **An `actor` cache** serialised every request, so one slow AVFoundation video
   decode stalled every thumbnail queued behind it and the list looked empty.
3. **`Task.detached` inside `.task(id:)`** meant that when SwiftUI rebuilt the list
   and cancelled the view's task, execution stopped at the `await` — so neither the
   image nor the failure state was ever set and the row stayed blank forever.

What works: `NSCache` (already thread-safe, evicts under pressure) plus a concurrent
`DispatchQueue` and a checked continuation. Video goes through `AVAssetImageGenerator`
at 10% of the duration; ImageIO cannot open a movie container at all.

**A note for anyone screenshotting the app to check it:** video frames take a few
seconds to decode. Capture too early and every thumbnail looks broken. That mistake
cost more time than all three bugs above.

## Measured on this machine

```
10 performance cores
extract      139–143 files/s   (22.5 single-threaded)
10,913 files scan 1.2s · extract 78s · cluster 0.2s · resolve 0.1s
ballot back-test  1,354 days in 9s
```
