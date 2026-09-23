# Build log & edge-case log

The record of building PhotoMerge and running it for real — first on a 22,940-file
library, then a second round folding in 2,531 more photographs found later in a cloud-storage folder.
`PLAN.md` is the design and `README.md` the runbook; this is what actually happened,
including the parts the plan got wrong and the parts *we* got wrong while checking
our own work.

Written for Phase 2 (PLAN §10). README §8 is blunt about why: **this log is the
asset.** The code is reproducible by anyone; the list of input shapes that break a
photo merger is not, and each entry here is a test fixture someone else would
otherwise pay for in lost photographs.

Closed after round two, with the merged library imported and verified. §6 is the
short version for anyone starting their own.

---

## 1. What was done, in order

Dates are 2026-09-17/18. Every stage is re-runnable and writes only to the catalog
until stage 5.

| # | Stage | Command | Outcome |
|---|---|---|---|
| M0 | Survey | — | 12,610 Google + 6,363 Apple files; assumptions checked against real data before building |
| M1 | Catalog, scan, extract | `scan`, `extract`, `status` | 18,973 files, 0 failures, 8 min. Sidecar match **100.00%** |
| M2 | Exact + pixel clustering | `cluster`, `report` | 12,901 assets. Tier B found only 7 beyond tier A |
| — | **Mac re-export** | `osxphotos export --exiftool` | +2,631 files. Tier B jumped to 2,566 |
| — | **Cloud originals** | Photos setting | +1,336 files; 2,288 → 1,106 missing |
| M3 | Perceptual tier | `cluster --radius 4` | BK-tree + verification cascade + C2. 10,008 assets |
| M5 | Metadata resolution | `resolve` | 100% dated, 100% zoned, 76.6% located |
| M6 | Write | `write --apply --move` | 10,286 files, 42.3 GB, **all verified byte-identical in pixels** |
| M6c | Live Photos | `livephotos --apply` | 158 converted, 150 motion clips lifted |
| M6b | Stage & reclaim | `trash`, `reclaim --confirm` | 12,654 files, **29.9 GB freed** |
| M7 | Explain & report | `explain`, `review`, `report.html`, `undo` | — |
| M8 | Import | Photos → File → Import | **10,017 items, every file accounted for** |

Final: **22,940 files → 10,017 items**, 72.2 GB → 42.3 GB, 157 tests.

**Order that mattered.** Re-exporting the Mac library *after* M2 but *before* M3 was
accidental and turned out to be essential — see §3.1. Doing the iCloud download before
the re-export would have saved a second export pass.

---

## 1b. Round two — folding in a second source

PLAN §5b's "Rounds" design says an output tree becomes an input. It was exercised for
real when 2,531 photographs surfaced in a cloud-storage folder after the first import, in eleven folders,
several of them named after places.

| # | Stage | Command | Outcome |
|---|---|---|---|
| R1 | Scan both | `scan --src RESULT --src more_Photo` | 12,568 entries, 3.3 s |
| R2 | Extract | `extract` | 12,565 files, 139,775 claims, 454 s |
| R3 | Cluster | `cluster` | 12,565 → 10,833 assets, 151 s. 1,446 photos + 17 videos were duplicates of round one |
| R4 | Resolve from prior | `resolve --prior result.sqlite` | manual overrides survived; a year-long zone rule propagated to 85 *new* assets |
| R5 | Locate | folder gazetteer + time-match | 741 assets located; coverage 86.5% → **91.0%** |
| R6 | Write | `write --out RESULT2 --apply` | 11,102 files, 43.6 GB, all verified byte-identical |
| R7 | Live Photos | `livephotos` | 269/269 pairs already carried their identifiers — nothing to do |

**`--prior` works.** Round one's conclusions came back intact: 208 wallpapers still
pinned to one placeholder date, all 414 assets of a year-long zone rule still on it, a
city pin grown from 391 to 473 as new photographs joined it. One check *appeared* to fail
— a campus pin fell from 24 assets to 12 — but the coordinates we had embedded into the
files last round were read back from EXIF ending `…7030` where we wrote `…7028`, a rational
encoding rounding. An exact-string count found half of them. The right lesson is not
about floating point: **once a round writes its conclusions into the files, the next
round sees them as ordinary measured metadata**, with the source changed from `manual`
to `exif`. That is correct, and it means round *n+1* cannot distinguish our inference
from the camera's measurement. Anything a later round must be able to override has to
stay in the catalog, not only in the file.

---

## 2. Edge-case log

Each entry: the input shape, what it broke, and what fixed it. These are the
fixtures.

### 2.1 Google Takeout sidecars

**Two `(n)` collision conventions coexist in one export.**

```
IMG_0088 (1).jpeg   ->  IMG_0088 (1).jpeg.supplemental-metadata.json   (suffix on the media)
IMG_0899(1).HEIC    ->  IMG_0899.HEIC.supplemental-metadata(1).json    (suffix on the sidecar)
```

Note the space in one and not the other. Handling only one convention loses ~29 files'
metadata silently. *Fixture: both shapes in one directory.*

**Extension case need not agree.** `IMG_0460(1).MOV` pairs with a sidecar written
against `.mov`. Every lookup goes through a case-folded directory index.

**`~N` is a copy marker, not an edit marker.** `NAME~2-edited.jpg` inherits from
`NAME~2.jpg`, **not** `NAME.jpg`. Stripping `~2` along with `-edited` was the only
thing that kept the match rate below 100%. Two different normalisations are needed:
one for finding a sidecar (strip `-edited` only) and one for grouping captures (strip
`~N` too).

Result: **12,610 of 12,610 matched.** The plan predicted 98%.

### 2.2 The extension is not the type

3 files with **no extension at all** that are QuickTime MOV. `.MP` is MP4;
`.mp_original` is QuickTime; `X.MP.jpg` is a JPEG whose *stem* contains another
extension. 163 files in total that extension-based detection ignores.

Fix: magic bytes, always. ISO-BMFF needs the `ftyp` brand read to tell HEIC from MP4 —
they are the same container.

### 2.3 Google Motion Photos hold four streams

```
stream 0: hevc 1440x1080, 54 frames   <- the motion
stream 1: hevc 2048x1536,  1 frame    <- the still, at HIGHER resolution
stream 2: data, 54 frames
stream 3: data,  1 frame
```

`ffmpeg -i X.MP -c copy X.mov` selects by resolution and therefore keeps **the still**:
3,695,971 bytes in, **197,996 out**, motion silently gone. `-map 0:v:0` takes the clip.

Guard added: refuse any remux keeping under half the source size. It fired for real
during development when a temp filename left ffmpeg unable to infer a container.

### 2.4 exiftool cannot create an Apple MakerNotes block

Writing a `ContentIdentifier` onto a Google-produced JPEG **fails silently** — exiftool
reports `1 image files unchanged` and does nothing. All five plausible tags fail:
`-MakerNotes:`, `-Apple:`, `-XMP:`, `-XMP-apple-fi:`, `-QuickTime:ContentIdentifier`.

Fix: delegate to [`makelive`](https://github.com/RhetTbull/makelive) (ships with
osxphotos), which writes the MakerNotes identifier on the still and the `Keys` atom on
the movie, and offers `is_live_photo_pair` as a read-back check. A standing test
asserts exiftool *still* cannot do this, so the dependency can be dropped if that
changes.

### 2.5 Batch timestamps are not capture times

**1,428 EXIF claims land within four minutes of each other on 2018-12-30** — a phone
restore stamping files. 490 QuickTime claims on the day an export ran. A real capture
histogram is nearly flat; a spike is a machine.

Google's `photoTakenTime` **inherits the same stamps** (165 assets on one minute),
because it was read from the same EXIF. Detection must cover sidecars, not just EXIF.

Rule: any `exif`/`quicktime`/`google_json` claim on a minute shared by ≥20 distinct
assets has its confidence cut to a quarter. 621 claims downgraded.

### 2.6 A capture time can only be wrong *late*

Copying, re-encoding, restoring and re-uploading all push a timestamp **forward**;
nothing pushes it back. So on a genuine disagreement the **earliest plausible claim
wins**, even from a source the precedence table ranks near the bottom.

This is what lets a messaging-app filename epoch (`mmexport1500000000000`) beat a rank-1 EXIF
tag that records a 2018 re-save of a 2015 photo. 944 assets disagreed; 504 by more
than a day.

### 2.7 `QuickTime:CreateDate` is UTC by specification

exiftool renders it `+00:00` whatever zone the camera was in. Recorded as the shooting
offset, **181 videos claimed UTC as their own wall clock** and would have been named
and filed hours out. Only `Keys:CreationDate` knows the zone.

Related: a QuickTime atom that was never set reads back as **the Unix epoch**, and an
"earliest wins" rule takes it seriously — five videos landed in `1969/12/`. Reject
anything before 1990.

### 2.8 A wall clock must be re-anchored after its zone is found

A local time with no offset has to be read as UTC just to be comparable. If a zone is
derived afterwards, the instant must move with it — otherwise the file is filed and
named by a time that was never real. Found by a test asserting a filename matched its
resolved local time.

Corollary bug, self-inflicted: `datetime.fromisoformat("...T11:48:17").timestamp()`
interprets a naive value in the **machine's** timezone. The same catalog resolved
differently in Tokyo and Chicago — the exact defect the project exists to remove,
reintroduced while fixing something else.

### 2.9 phash bit entropy cannot detect a flat image

The plan specified "low phash bit entropy" for the sky/wall/blank-screenshot guard.
**Measured bit-mean is exactly 0.500 for every image** — the hash thresholds DCT
coefficients against their own median, so half the bits are always set, for a blank
wall and for pure noise alike.

Grayscale standard deviation separates them: **0.0 / 2.7 / 72.3** for a wall, a wall
with one digit, and noise.

**Tile grid matters more than the threshold.** Screenshots differing in a single digit
score 3.4–4.4 on an 8×8 grid — indistinguishable from genuinely identical night-sky
frames at 0–3. At 32×32 the digit pairs rise to 20–33 while real pairs stay under 5.5.

### 2.10 SSIM is unreliable on natural texture

Two frames of the same photo scored **SSIM 0.167** because foliage moved between them.
Genuinely identical photos re-processed with different tone scored 0.66. True
re-encodes scored 0.95.

Geometry (ORB + RANSAC inliers) and per-tile difference are the trustworthy signals;
SSIM is supporting evidence only. Same-aspect pairs with hundreds of inliers are one
photo processed twice, whatever SSIM says.

### 2.11 A still can draw two companions

A long unrelated video that merely shares a name was attached as a Live Photo
companion alongside the real motion clip — and, sorting first, took the primary output
name. 7 stills drew two companions; in 2 the wrong one won (36 s and 14 s videos
against 2.8 s and 1.9 s motion clips).

Rule: **a still keeps at most one companion, and `content_id` decides** — Apple's own
assertion of which movie belongs to which still. A rival without that identifier is
not a companion at all.

Photos itself was more careful than this code: it paired on `ContentIdentifier`
regardless and produced the right result anyway.

### 2.12 A movie absorbed into a Live Photo loses its filename

The import reconciliation compared filenames and reported two files missing. They had
been paired correctly — a movie consumed into a Live Photo takes the **still's** name,
so it never appears under its own.

Reconcile by arithmetic instead:

```
live_photo_items × 2  +  single_items  ==  files_on_disk
269 × 2 + 9,748 == 10,286   ✓
```

This nearly caused real damage: the wrong conclusion was "delete two items and
re-import", which would have destroyed correctly imported photographs.

### 2.13 iCloud shared albums are a separate world

"Download Originals to this Mac" pulls everything the account **owns** and then stops
dead — 2,288 → 1,106 missing, of which **1,105 were shared-album photos**. They are not
covered by that setting, do not count against storage, and re-sync to any library
signed into the account.

They are also **downsampled**: 2049×1537 (~3 MP) against the owner's 4032×3024. The
full-resolution originals live in the contributors' accounts and no permission grant
reaches them. `cloud_owner_hashed_id` identifies who contributed what.

### 2.14 VS Code cannot obtain Automation permission

`osxphotos import` drives Photos via Apple Events. macOS refuses to even show the
Automation prompt for an app whose `Info.plist` lacks `NSAppleEventsUsageDescription`,
which **Visual Studio Code does not have** — so it never appears under Privacy &
Security → Automation and the error is `-1743`, not a prompt.

Workarounds: run from Terminal.app, or use Photos' own **File → Import**, which needs
no permissions and pairs Live Photos correctly because the pairing comes from the
embedded `ContentIdentifier`, not from the importer.

---

### 2.15 A camera clock can be fitted against a phone's GPS track

A mirrorless camera wrote 44 frames of a five-day road trip with **no timezone tag at
all**. The pipeline guessed one per asset and produced four different answers across
the same trip — `-05:00` x22, `-07:00` x16, `+00:00` x3, `-04:00` x3. No guess was
right: every frame was 4h05m late and ten of them sat on the wrong calendar day.

A phone that was on the same trip is a clock standard. Take its measured fixes as
`(t_i, lat_i, lon_i)`, then for a candidate shift `s` score the camera's wall clocks
`w_j` by `median_j min_i |w_j - s - t_i|`. The true shift minimises it, because a
photographer carrying both devices shoots them within minutes of each other; a wrong
shift lands the frames in the gaps of the track and the median blows up.

```
shift   median gap   within 5m
-07:00     109 m        14/44     <- what the pipeline had assumed
-04:00      13 m        25/44
-03:00       4 m        27/44
-02:55       1.3 m      28/44     <- the answer
```

The minimum is sharp: one hour either side of it triples the median. `-02:55` is not
a real zone, and that is the point — the clock was set by hand and left to drift, so
the fit recovers a *drift*, not an offset. Scan whole hours first to find the basin,
then minutes to find the bottom.

Once the clock is right the same track locates the frames: nearest fix in time, which
spread them across five distinct stops of the trip — with a median error of about a
minute of travel. The owner remembered the whole trip by its best-known stop; the track
disagreed, and the track was right. **Ground
truth from memory sets the region; the track sets the frame.**

### 2.16 A measured fix is also a timezone assertion

Coordinates plus an instant determine a UTC offset exactly (`timezonefinder` +
`zoneinfo`). That makes every measured fix a free audit of the offset resolved beside
it. Across the catalog, **239 of 7,459 assets carrying a measured fix had an offset
their own coordinates contradict**:

```
 137   US offsets on assets whose GPS is in East Asia
  60   US zone confused with a neighbouring US zone
  42   other
```

Nine of them were videos stamped `-05:00` with GPS in a city on Central time
(`-06:00`); three were stamped `-04:00` at a spot where a `.mov` taken minutes earlier
correctly carried `-07:00`.

**Only a measured fix may vote.** Applying this audit for real, the first pass found
855 assets instead of 411, because it let *inferred and hand-pinned* locations decide a
timezone too. That is circular: a place derived from a folder name or a contact sheet
cannot then certify the zone of the clock that dated it. Restricting the audit to
`gps.source` in (`exif`, `quicktime`, `xmp`, `google_json`) gave 411. The 388 excluded
were one trip abroad, where the camera wrote a bare wall clock and there is *no
evidence* whether it was set to local or home time — so they were left wrong
rather than guessed at. An audit that can be fed its own output is not an audit.

The trap: these assets' **filenames were already correct** and only the stored offset
was wrong, so a rename pass driven by `datetime_utc + utc_offset` proposed to move 14
correctly-named files to wrong names. A dry run caught it. Anything that renames from
a resolved date must be scoped to the assets whose date actually changed, never to
"every asset whose name disagrees with the catalog" — the disagreement can just as
easily mean the catalog is wrong.


### 2.17 Correcting a zone: which field is authoritative decides whether names move

Two groups needed the same correction — a wrong `utc_offset` beside a now-known
location — and the correct repair was opposite in each.

**Group A — a year in one city (329 assets).** An Android phone writes
`DateTimeOriginal` as *local* time. Filename, EXIF wall clock and the catalog's local
time all agreed (`16:05:57`); only the offset was wrong (`-08:00`, should be `+08:00`). The
**wall clock is authoritative**: hold it, recompute `datetime_utc = wall - 8h`. The
UTC instant moves 16 hours and not one filename changes.

**Group B — one afternoon in a US city (24 assets).** Here `datetime_utc` came from `google_json` and
`quicktime`, which record true UTC. The **UTC is authoritative**: hold it, and the
local time moves from `15:21:41` to `14:21:41` — so every name moves back an hour.

Getting this backwards is silent and total. Holding UTC for the 2017 group would have
shifted 329 correct filenames by 16 hours; holding the wall clock for group B
would have left 24 files an hour wrong forever. The test is simply *where did this
timestamp come from* — an EXIF wall clock with no zone tag, or a format that is UTC by
specification (§2.7). A cross-check is cheap and settles it: in the city's true zone
the group runs 13:27 to 15:00, a coherent afternoon, and the previous day's videos were
already named on `-06:00`.

Ground truth arrives as a place, never as a zone. Deriving the zone from the place is
the easy half; deciding which recorded field has to give way is the half that bites.


### 2.18 A folder name is a trip name, not a location

Eleven folders, several named for places: a national park, a country, a palace garden,
a university, a mountain, a school. Treating a folder name as a per-photograph location
is wrong in both directions.

The country folder held 408 photographs over three weeks; the trip ran through five
cities some 2,000 km apart. The national-park folder held 493 frames of a trip that also
took in a neighbouring park and the drive in — pinning them all inside the park would
have been as wrong as pinning them all to one city.

The rule that came out of it, in priority order:

1. a **measured fix** on the photograph itself always wins;
2. otherwise the **nearest measured fix in time**, subject to a travel bound (§2.19);
3. otherwise the folder name, *only* where the folder names a specific place
   (the garden, the mountain, the school) rather than a region;
4. otherwise a standing rule the owner gave ("that whole year I lived in one city");
5. otherwise leave it unlocated. An empty map pin is honest; a wrong one is not.

Of 1,803 new assets this located 1,744 and left 59 alone.

### 2.19 Nearest-in-time needs a travel bound, and a sanity check to notice it doesn't

Matching an unlocated frame to the nearest measured fix is only sound while the
photographer cannot have moved far in between. With a 12-hour window, 175 national-park
frames were assigned to one spot — a cluster of **four** phone fixes recorded in a single
hour at a roadside stop in a neighbouring state. The nearest fix in time was three hours
and a mountain range away.

Tightening to 60 minutes — `TRAVEL_MAX_MINUTES`, the bound the pipeline already used
for its own inference — left 186 of 253 matched with a **median gap of 19 minutes**,
and the remainder fell back to the folder pin. Reusing the existing constant beat
inventing a new threshold: the codebase had already reasoned about how far a person
travels in an hour.

What actually caught the error was a cheap assertion written alongside the matcher:
*do the results land inside the park's bounding box?* It reported 175 outside. The
box was too strict to be a **rule** — the trip legitimately included places outside it —
but it was an excellent **alarm**. A sanity check does not have to be
correct to be useful; it has to be correlated with being wrong.

### 2.20 A method needs a stated precondition, or it will be trusted where it cannot work

§2.15 recovered a camera clock by fitting it against a phone's GPS track: a sharp,
unique minimum at −02:55, median gap 1.3 minutes. The same fit was tried on a second
camera (a DSLR) whose frames looked suspicious, and it produced nonsense that *looked* like a
result:

```
shift   median gap          shift   median gap
 +1h        6 min            −5h        7 min
+11h        6 min            −8h        8 min
```

Four different answers, all equally good. The reason is the reference data, not the
camera: 696 phone fixes spread across eight days is roughly one every fifteen minutes
of waking time, so *any* offset lands near something. The method's precondition is
**sparse reference fixes**; the first camera's trip had 357 fixes with real gaps, and the
minimum was unmistakable.

Report the shape of the objective, not just its argmin. A flat landscape with several
equal minima is a refusal to answer, and must be read as one.

### 2.21 Verifying "safe to delete" is where a merger actually risks the photographs

249 videos had been staged aside as duplicates. Before unlinking them, each had to be
shown to survive in the new tree. Two verification attempts were written, and **both
were wrong, in opposite and instructive ways**.

**First: a test the design forbids.** Compare `stream_hash` of each staged video
against the kept ones. It reported 214 of 249 missing — apparent catastrophic loss. But
video deduplication matches on duration plus three sampled frames precisely *so that a
re-encode of the same recording counts as a duplicate* (§5). A kept copy that is a
different encode has a different stream hash **by design**. The test contradicted the
specification it was checking. The giveaway was in its own output: pairs like
`…_030558.mov` / `…_160558.mov`, same day, identical size, thirteen hours apart —
the timezone-artifact duplicates the dedup exists to catch.

**Second: a correct test made quadratic.** Reuse `videoverify.verify()` per candidate
pair. `_frames()` spawns three `ffmpeg` processes per video **per call** and caches
nothing, so every kept video's frames were re-extracted once per staged video that
shared its duration bucket. Twenty minutes produced 80 of 249 results.

Hashing each video's frames exactly once and comparing the hashes as data — the same
rule, the same constants — did all 892 videos in **59 seconds**: 249 of 249 confirmed.

Three things generalise. A verification must be derived from the *same* definition of
identity as the thing it verifies, or it is a different question wearing the same name.
An expensive primitive with no memoisation is a correctness-preserving trap: the
library is right and every caller that loops is quadratic — `_frames()` should cache on
the file's identity. And a verification that cries wolf is not merely useless; if the
answer had come out the other way, the same carelessness would have licensed deleting
4.7 GB of irreplaceable video.

### 2.22 Structural hashes are blind to a colour grade

Two Google Photos `_edited` renditions were classed as duplicates of their originals
and staged for deletion. One deserved it; one did not.

```
                       dHash distance    mean |pixel difference|
lake at dusk                        1              1.13 / 255     re-encode
pasta, re-graded                    0             18.05 / 255     a real edit
```

dHash and pHash describe *structure* — edges and gradients survive a saturation and
warmth change untouched, so a deliberate colour grade scores a perfect match. The
photograph is "the same photograph" by every geometric test and still a different
picture to look at.

Before discarding anything whose name says `edited`, `-EFFECTS` or similar, add a
tonal comparison: mean absolute pixel difference after resizing to a common size.
Structure says *same scene*; tone says *same rendering*. Deduplication needs both.

### 2.23 Do not measure free space immediately after deleting

Four large deletions were made and each was measured seconds later with `df`:

```
deleted                 returned at once
Photos library  46 GB          2 GB
RESULT          37 GB          8 GB
video_trash    4.7 GB        0.7 GB
```

An APFS clone story was constructed to explain the shortfall — plausible, since
`write` had been patched to use `clonefile`, and exiftool skips files whose metadata
is already correct, which would leave clones intact. It was wrong. Roughly 23 GiB
arrived later with nothing done to cause it: APFS defers block reclamation, and a
tree of ten thousand files takes its time.

Two habits follow. Read `diskutil info` container figures rather than `df` on a
volume that shares a container, and check for local snapshots and purgeable space
before believing any delta. And when a measurement disagrees with expectation,
**re-measure before reaching for a mechanism** — a confident explanation of a
measurement artifact is worse than no explanation, because it stops the enquiry.


### 2.24 `EXIF:DateTimeOriginal` is not the only capture date, and not the one that wins

Every re-dating pass wrote `EXIF:DateTimeOriginal`, `EXIF:CreateDate` and
`XMP-photoshop:DateCreated`. After a full import, twelve photographs sat on the wrong
date in Photos anyway. The files were not at fault — they carried *other* capture-date
tags that Photos prefers:

```
EXIF:DateTimeOriginal      2013:05:04 18:10:02   <- what we wrote
XMP-xmp:CreateDate         2015:06:07 09:10:02   <- what Photos used
IPTC:DateCreated           2015:06:07
IFD0:ModifyDate            2015:06:07 09:21:14
```

A file that has ever passed through an editor carries an XMP/IPTC history, and those
fields outrank the EXIF pair on import. The symptom is unmistakable once seen: two
frames shot **five seconds apart**, `…_064159.jpg` and `…_064204.jpg`,
landed **two years apart** in the library, because only one of them carried the stale
IPTC block.

Across the tree, 504 images had a competing date tag disagreeing with
`DateTimeOriginal`; 397 of them in fields that can outrank it. Only 12 actually
misfiled, so Photos' precedence is not a simple "IPTC always wins" — which is exactly
why the fix should not try to model it. Write **every** capture-date field to the same
resolved value and the question of precedence disappears:

```
-EXIF:DateTimeOriginal  -EXIF:CreateDate
-XMP-xmp:CreateDate     -XMP-photoshop:DateCreated
-IPTC:DateCreated       -IPTC:TimeCreated
```

`IFD0:ModifyDate` is deliberately left alone: it means *last modified*, and is
legitimately later than capture.

The general rule: a metadata *writer* must set every field a *reader* might consult,
because you do not control which reader runs next. Setting the field the specification
calls authoritative is not enough.

### 2.25 Verify an import against the library's own database, in the library's own terms

Checking the import meant comparing 10,833 assets against the catalog. The first
comparison reported **843** wrong dates — an apparent disaster. The real number was
**12**.

Apple Photos stores `ZASSET.ZDATECREATED` as an instant, with the capture zone kept
separately in `ZADDITIONALASSETATTRIBUTES.ZTIMEZONEOFFSET`. The query had rendered that
instant with SQLite's `'localtime'` — the *machine's* zone — so every photograph taken
in `+08:00` appeared to be a day out. The correct reading adds each asset's own stored
offset:

```sql
datetime(ZDATECREATED + 978307200 + ZTIMEZONEOFFSET, 'unixepoch')
```

`978307200` converts Apple's 2001 epoch to Unix. With that, 843 collapsed to 12, and
the stored offsets matched the catalog for all 10,833 — confirming the zone corrections
of §2.16 had landed.

This is the same failure as §2.23 in a different costume, and it is the one to watch
for in any verification tool: **the instrument was wrong, not the thing measured.** A
check that reports catastrophe deserves the same scepticism as one that reports
success — more, because panic makes bad repairs. Re-derive the measurement before
acting on it.


## 3. Where the plan was wrong

Kept deliberately. A design document that only records what worked teaches nothing.

### 3.1 "The pixel tier does most of the real work" (§3.1-B)

Measured twice, opposite results:

| Sources | Clusters needing tier B |
|---|---|
| Takeout + a plain Apple dump | **7** |
| the same, plus an `osxphotos --exiftool` export | **2,566** |

Two copies straight out of Takeout are *byte*-identical, so tier A has them. An
`osxphotos --exiftool` export rewrites metadata into every file, producing copies with
**identical pixels and different bytes** — invisible to A, certain under B.

**The tier's yield is a property of the export tool, not of the library.** Corollary
for Phase 2: tier B is what makes re-exporting a source cheap. Without it, exporting
the same library again with better metadata adds thousands of files no certain tier can
reconcile.

### 3.2 "Default the dHash radius to 2, not 6"

An earlier pass measured the **unverified** candidate graph and found a naive
transitive closure chaining 14 assets at radius 2, 67 at radius 4, **217 at radius 6** —
and concluded the radius had to be tight. The measurement was real but answered the
wrong question: the closure is never taken over raw candidates.

Verifying all 11,758 candidates and slicing by distance:

| radius | candidates | confirm | review | reject | assets merged | **longest chain** |
|---|---|---|---|---|---|---|
| 2 | 7,033 | 6,316 | 127 | 314 | 2,813 | **6** |
| **4** | **8,581** | **6,605** | **183** | **1,407** | **2,945** | **6** |
| 6 | 11,758 | 6,655 | 202 | 4,398 | 2,983 | **6** |

**The longest chain is 6 at every radius.** Tier D removes the explosion entirely, so
the radius is a recall/compute dial, not a safety dial. Radius 2 was also *costing*
real duplicates — a q95-vs-q40 recompression sits at distance 3.

### 3.3 The Motion Photo recipe (§5d)

Both steps wrong. See §2.3 and §2.4. The plan's own instruction — *"validate on 5 pairs
before running all 150"* — is what caught them. It was right to write that down.

### 3.4 The flat-image guard (§3.1-D3)

Specified an impossible mechanism. See §2.9.

### 3.5 Estimates that held up

Worth recording too, since they justified building on them:

| Predicted | Actual |
|---|---|
| ~10,169 union assets | **10,008** |
| 1,646 HEIC-vs-JPEG pairs where Google holds the original | **1,790**, HEIC kept in all 1,790 |
| "Zero genuinely orphaned files" | confirmed, 100% sidecar match |
| ~3,000 duplicates only tier C can see | 2,945 at radius 4 |

The §0 survey-first discipline paid for itself. Every number that mattered was within
a few percent, and the two that were wrong (§3.1) were wrong in an instructive way.

---

## 4. Things that made the difference

Not lessons in the abstract — the specific practices that caught real defects.

**Survey before building.** §0 killed two assumptions and added a file format before a
line of the rewrite existed.

**Measure instead of asserting.** Every claim in `PLAN.md` that turned out wrong was
one taken on reasoning alone. Every claim that held was one checked against the export.
The same failure recurs outside the pipeline: three storage claims in round two were
asserted from a `df` reading taken seconds after an `rm`, and all three were wrong
(§2.23). An explanation invented to cover a measurement is worse than an open question.

**Suspect the instrument first.** Round two's three false alarms were all measurement
error, not data loss: 214 videos "missing" from a hash test the design forbids (§2.21),
33 GB of disk "unreclaimed" that APFS simply had not freed yet (§2.23), 843 photographs
"misdated" by a query that ignored each asset's stored zone (§2.25). Every one looked
like catastrophe and every one was the checker's fault. The tell is scale: a defect that
would have to have been introduced by a step that touched far fewer files than the
number now failing is almost always a bad check.

**Verify a deletion against the definition that authorised it.** The most dangerous
code in a photo merger is not the matcher, it is the check that says "safe to delete
now". Round two wrote that check twice and got it wrong twice (§2.21) — once by testing
byte equality where the design explicitly permits re-encodes, once by making a correct
test quadratic. Neither failure was in the pipeline; both were in the driver written
around it.

**Validate on a small sample before the full run.** Five Motion Photo pairs exposed two
bugs that would have silently destroyed 150 motion clips. Sixty files exposed the
epoch-date bug before 10,000 were misfiled.

**Look at the pictures.** Contact sheets caught a burst being collapsed as duplicates —
arm positions differed between frames. No metric flagged it.

**Look at the pictures — and then look at them again for a different reason.** A trip
with no GPS was reconstructed from the photographs themselves: a per-day contact sheet
identified a landmark in each city along the way. The owner supplied one correction — a
city visited between two others — and the data corroborated it independently: one day
had *zero* photographs, the flight. Reading the images is
not a fallback for when metadata is missing; it is a source of evidence in its own
right, and it is checkable against the metadata that does exist.

**Take the owner's ground truth as the region, not the frame.** "I was at the national
park that week", "that whole year I lived in one city", "these are all from the lake" — each was
true and each was coarser than the data. Memory reliably gives the trip; the track
gives the moment. Where they disagreed, the track was right every time, and saying so
produced better results than either source alone (§2.18).

**Write the cheap assertion next to the clever matcher.** A crude national-park bounding
box was too strict to be a rule and perfect as an alarm — it caught a 12-hour matching
window that had scattered 175 frames across three states (§2.19).

**Rank the audit by weakest evidence.** Nobody reviews 8,000 merges. Reviewing the ten
flimsiest is tractable, and if those are right the rest almost certainly are. This
ranking itself had a bug: it scored by SSIM, so merges confirmed by *other* rules
scored 1.0 and never surfaced — the two newest and least proven paths were the only
ones the audit could not see.

**Make deletion structurally dependent on verification.** `decision.verified_at` is
stamped only after a written file is re-read and its pixels hash-matched. `trash` and
`reclaim` refuse to act without it. Proven by test: with `--no-verify`, staging moves
nothing at all.

**Write the manifest incrementally.** In move mode a crash halfway through leaves the
sources partly renamed, and the manifest is the only record of where anything went.

---

## 5. State at the end of round two

```
RESULT2/                        10,832 assets + 1 restored edit = 10,833
                                11,102 files, 43.6 GB, 269 Live Photo pairs
                                325 wallpapers parked on 2010-02-01
                                9,674 of 10,507 real assets located = 92.1%
round2.sqlite                   the product; explain() works from this alone
result.sqlite                   round one, kept as the `--prior` for round three
the Photos library              10,829 items, imported and verified
```

Cumulative: **22,940 + 2,531 source files → 10,829 items in Apple Photos.** 160 tests.

**The import reconciles exactly.** Every asset was compared against the catalog using
the library's own stored offsets (§2.25): 0 wrong dates, 0 duplicate filenames, 0
untracked items, 0 in trash, 269/269 Live Photo pairs intact. The four assets in the
catalog but not the library are wallpapers the owner deleted on purpose. One asset
keeps the wrong hour on the right day — judged not worth another edit.

**What round two bought.** 2,531 photographs from the second source yielded 1,067 genuinely new
assets; 1,446 photos and 17 videos were duplicates round one had already kept. Location
coverage rose 86.5% → 92.1%. Three assets were *upgraded*, the second source holding the original
where `RESULT` had only a downscaled copy (4032×3024 replacing 1440×1080, twice). 411
timezone contradictions were closed, and 117 wallpapers the caption rule could not see
were found by other means (no camera, no location, exact phone-screen resolution, one
download burst) and parked with the rest.

**Open, and deliberately not carried further here:**

* one device never catalogued and without a cloud backup — the only remaining item
  where pictures could be *lost* rather than merely imprecise;
* 832 real assets with no location, scattered across a few years;
* one trip's clock zone, unrecoverable from the files (§2.16).

**Phase 2 gate (§12):** ran end-to-end ✅ · output trusted enough to delete sources ✅
(29.9 GB in round one, the whole of `RESULT` in round two, each after an explicit
supersession proof) · edge-case log ≥5 entries ✅ (**25**) · *still want to maintain it
in three months* — round two was built and run in an afternoon on top of round one's
catalog, and the third round needs no new code. That is the first real evidence the
design survives contact with its own output.

---

## 6. If you are reading this to build your own

The code is the easy half. What this log is actually worth:

1. **Sections 2.1–2.25 are test fixtures.** Each is an input shape that broke something,
   with the symptom and the fix. Building a merger without them means rediscovering them
   on your own photographs.
2. **The dangerous code is not the matcher.** It is whatever decides "safe to delete
   now", and whatever *checks* that decision. Round two's matcher was right every time;
   its drivers and its checkers were wrong four times (§2.21, §2.23, §2.25).
3. **Ground truth from a person is a region, not a frame.** "I was at the national park",
   "that whole year I lived in one city", "these are all from the lake" — each true, each coarser
   than the data, and the data was right wherever they disagreed (§2.18).
4. **Write every field a reader might consult** (§2.24), and **judge a timezone only by
   a measured fix** (§2.16). Both rules were learned by getting them wrong first.
5. **Keep the catalog, not just the output tree.** Once conclusions are embedded in the
   files, the next round cannot tell them from the camera's own measurements (§1b).
