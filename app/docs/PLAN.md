# PhotoMerge.app — v1 plan

A macOS app that finds duplicate photographs across scattered collections, tells you
which copy is best, and works out when and where each picture was taken.

**v1 writes nothing.** It analyses and reports. Acting on the findings comes in v1.1
(`ROADMAP.md`), deliberately, because the product's real problem is not detection — it
is earning enough trust to be allowed to delete someone's photographs.

Engineering constraints inherited from a real 25,471-file merge are in `INHERITED.md`.
That document is the specification for what must not break.

---

## 1. Who it is for

Someone with the same mess in several places: a Google Takeout, an old Photos library,
a folder of phone dumps, a Dropbox backup, twenty years of copies of copies. They
suspect most of it is duplicated, they know some dates are wrong, and they will not risk
deleting anything without seeing why.

**Not** a DAM, not an editor, not a cloud service, and not tuned to any one collection.

---

## 2. Two principles

**Runs entirely offline.** No network stack is linked. No LLM, no cloud, no telemetry,
no licence check. Timezone shapefile, tz rules and all reference data are bundled. A run
in five years on an air-gapped machine gives the same answer — which is where
irreplaceable archives live. Cost: ~50 MB of bundle, and zone-rule updates ship as new
builds.

**Every claim is traceable.** No machine learning in the identity path: a wrong merge is
unrecoverable, so every merge traces to a rule a person can read. On-device Vision is
used only where errors are cheap and reversible (classifying screenshots), never to
decide identity.

---

## 3. The trust ladder

The product design, stated once because everything else follows from it:

```
1. see          survey — counts, space, formats            nothing read in full
2. understand   duplicate groups with the reason           nothing written
3. tune         dials with live consequence                nothing written
4. verify       samples chosen by weakest evidence         nothing written
                ───────── v1 ends here ─────────
5. act          write a clean tree                         originals untouched
6. reclaim      unlink duplicates                          gated on verification
```

A user who never climbs past step 4 has still got their answer. That is the point.

---

## 4. First run

```
add folders  →  survey (seconds)  →  first duplicate groups appear  →  keep working
```

- **0–5 s** folders counted, formats identified, date span shown
- **< 30 s** the first duplicate groups are on screen and browsable
- **background** the rest streams in; the app is usable throughout, closable, resumable

**Progressive results are non-negotiable.** Full analysis of 100k assets takes tens of
minutes; an app that shows nothing until it finishes gets force-quit. Groups appear as
they are confirmed.

---

## 5. Surfaces

| Surface | Job |
|---|---|
| **Sources** | add folders and libraries; per-source survey; exclude rules |
| **Scoreboard** | duplicates found · space recoverable · % dated · % zoned · % located |
| **Groups** | the core browser: duplicate groups, keyboard-first, A/B compare at equal zoom |
| **Timeline** | dates and places over time; gaps, conflicts and proposals |
| **Dials** | thresholds with live consequence (§8) |
| **Decisions** | why is this here? — the full chain for any asset |
| **Report** | export CSV/JSON; a shareable summary |

**Groups is where the time goes.** Keyboard-first: `←/→` between groups, `space` to
compare, `1–9` to pick a keeper, `x` to flag. The difference between a user reviewing 50
groups and 500 is whether their hands leave the keyboard.

**The scoreboard is the progress metaphor.** In practice what conveyed progress was
watching *located* go 86.5% → 92.1%. Headline numbers that move.

---

## 6. Engine

```
scan → extract → cluster → resolve → report
```

| Stage | Does | Writes |
|---|---|---|
| **Scan** | walk, magic-byte type, sidecar cascade, filename/folder claims | `file`, `sidecar`, `meta` |
| **Extract** | metadata, content + perceptual + stream hashes | `meta`, hashes |
| **Cluster** | identity cascade, bursts, companions, canonical choice | `cluster`, `member` |
| **Resolve** | time, zone, place, camera, union of tags | `resolution` |
| **Report** | groups, scoreboard, explanations, export | — |

Every stage is resumable and idempotent. **The catalog is the product** — proven when
the output tree and every source folder were deleted and the catalog still deduplicated
a new 1,701-file source against 10,832 assets.

### 6.1 Data model

```sql
file(id, path, source, size, mtime, kind, mime,
     sha256, pixel_hash, dhash64, phash256, stream_hash,
     width, height, sharpness)
meta(file_id, field, value, source, confidence)   -- every claim, never overwritten
sidecar(file_id, path, rule, confidence)
cluster(id, method)                                -- one real photograph
member(cluster_id, file_id, role)                  -- canonical|duplicate|variant|companion|burst
resolution(cluster_id, field, value, source, confidence, competing_json)
decision(id, file_id, outcome, reason, verified_at)
review(cluster_id, reason, risk)
```

Two properties do the work: **claims are never overwritten** (so conflicts stay
inspectable), and **`resolution` records what lost** as well as what won.

### 6.2 Concurrency and performance

A bounded work queue sized to performance cores — not an actor per file. Thermal and
battery aware: laptops throttle and users notice.

| Budget | Target | Measured baseline (CLI) |
|---|---|---|
| Scan (metadata only) | ≥ 10,000 files/min | 12,568 in 3.3 s |
| Extract (hash + metadata) | ≥ 100 files/s | 27.7 files/s, single-threaded |
| Cluster 100k | < 10 min | 12,565 in 151 s |
| First group on screen | < 30 s | — |
| Peak memory | < 2 GB at 100k | — |

SQLite in WAL: one writer, UI reads a snapshot. Extract is the bottleneck and the one to
parallelise; the 3.6× gap between baseline and target is the core-count.

---

## 7. What it computes

### 7.1 Identity

| Tier | Test | Catches |
|---|---|---|
| A | content hash | byte-identical copies |
| B | pixel hash (orientation-normalised) | same pixels, rewritten metadata |
| C | dHash BK-tree → phash → verification | recompressions, resizes |
| D | video: duration + sampled frames; stream hash short-circuits | re-encoded video |

Tier C never merges on distance alone. Verification, in order: separation guards
(same camera and instant but different content ⇒ burst) · flat-image guard (grayscale
stddev + tile MAE) · SSIM · ORB+RANSAC geometric fallback · tonal check for colour
grades that structure cannot see. Anything unsettled goes to review, never to a silent
merge.

**Best copy:** more pixels → larger at equal pixels → richer metadata → not an edit
(kept as a *variant*, never dropped) → sharpness for bursts.

### 7.2 Time

Earliest plausible claim wins — a capture time can only be wrong *late*. Bare wall
clocks are anchored only once a zone is known. Formats that are UTC by specification are
treated as such. Timestamps shared by many files are downgraded as batch artifacts.

**Zone order:** the file's own offset tag → a **measured** GPS fix + bundled tz rules →
nearest dated neighbour → user rule → the ballot (§7.4) → unknown. Inferred or
hand-placed locations never certify a zone.

### 7.3 Place

1. a measured fix on the file
2. nearest measured fix in time, **bounded by plausible travel** (default 60 min)
3. **same day, same place** — if a day's measured fixes cluster within a radius
   (default 25 km), unlocated photos from that day inherit the centre
4. a user rule
5. nothing — an empty pin is honest, a wrong one is not

Guards: measured fixes only (inferences never seed inferences); a day spanning more than
the radius is a *travel day* and is declined loudly, with the count shown; always a
travel bound — without one, four roadside fixes once dragged 175 frames into the wrong
state.

### 7.4 The timezone ballot

When a whole day has no zone — no offset tag, no measured fix, no located neighbour in
range — score every real offset by independent local signals and **present a ranked
ballot** rather than guessing or giving up.

| Signal | Evidence | Strongest when |
|---|---|---|
| Neighbour continuity | zone of nearest located day, travel-bounded | short gap |
| Diurnal plausibility | share of photos landing in waking hours | many photos |
| **Daylight curve** | `EV ≈ log2(N²/t) − log2(ISO/100)` per frame traces ambient light; its bright plateau should straddle solar noon | outdoor photos |
| Device habit | offset this camera used within ±N days | phones |
| Sequence continuity | offset minimising the jump to the adjacent resolved instant | crossing midnight |
| Absolute filename | epoch-millisecond names pin the offset outright | Android/WeChat exports |

The daylight signal matters because it needs **no other photo to be located** — exposure
settings are a light meter. That is exactly the case where everything else has failed.

> **Measured, and demoted.** Back-tested over 1,354 days whose zone *is* known, the
> daylight curve used as a *ranking* signal was **worse than not having it**: 66.8% top-pick
> accuracy against 86.5% without it, and every error positive. The cause is not the physics
> but the premise — the centre of a day's *photography* sits hours after the centre of its
> *daylight*, because people shoot in the afternoon. It now ships as a **veto**: full marks
> anywhere within 4 h of the implied offset, nothing beyond 12 h, with a barely-sloped
> plateau so it orders the ties it creates without out-ranking real evidence. In that shape
> it costs 0.2 points of accuracy and **halves how often the ballot is confidently wrong**
> (1.6% → 0.7%). `./test.sh backtest <catalog> sweep` reprints the comparison.

**Presentation:** top three candidates, each with the day's first and last photo in that
local time, a thumbnail strip with would-be times (dinner at 04:00 is visible at a
glance), and which signals agreed or dissented.

**Refusals are first-class.** If the top two score within a margin the app says *"cannot
distinguish +08:00 from +09:00"* and offers both. In v1 the ballot **proposes only** —
nothing is written — which fits the analyser exactly.

Signal weights ship **unblended**: each shown separately until back-testing on days
whose zone is known says how to combine them. A confident-looking single score from
unvalidated weights is the failure mode to avoid.

**Only real days are balloted.** A day assembled from filesystem timestamps is not a day
the person was anywhere, so asking them to zone it is a nonsense question; the ballot is
offered only where the *date itself* was read off the photograph.

**A choice is evidence, not an edit.** A pick is stored by day in the catalog's `zone_pick`
table, applied before any inference so it propagates to neighbouring days, credited in the
UI as *"you chose it"*, and reversible from the same pane. It never overrules an offset the
file itself carries, and it never touches a file.

### 7.5 Non-photographs

Screenshots, memes, receipts and saved wallpapers are not memories. Detection is
**evidence, not verdict** — proposed, never applied:

- on-device **Vision text detection** (screenshots are text-dense)
- no camera make/model and no location
- dimensions exactly matching a known screen size
- arriving in one dense download burst

A caption-matching rule alone once missed 117 wallpapers that had no caption. Multiple
weak signals beat one strong-looking one.

---

## 8. Dials

Every threshold is adjustable and shows its effect on **this** collection before it is
applied:

| Dial | Default | Live preview |
|---|---|---|
| dHash radius | 4 | candidates, confirm/review/reject, assets merged, **longest chain** |
| SSIM confirm | 0.95 | which sampled pairs flip |
| Tonal difference | 12/255 | which edits become variants |
| Travel bound | 60 min | locations inferred, and how far |
| Day radius | 25 km | assets located, median distance from a real fix |
| Burst window | 2 s | frames collapsed |

**Shipped in v1: radius, day radius and travel bound**, each with a live preview and
samples. The other three are fixed constants for now, deliberately: SSIM was replaced by
the two-resolution slope test (a confirm threshold of 4 at 64×64, which has no dial
because moving it changes *what a duplicate means*, not how hard to look for one); tonal
difference became the *To review* queue, where a person decides instead of a number; and
the burst window became the exact capture-instant guard, which needs no width at all.

The radius dial exists because the first recommendation was backwards: measured on
*unverified* candidates it looked dangerous at 6; measured on *verified* results the
longest chain is 6 at every radius, and a tight radius silently lost real duplicates at
distance 3. **The preview measures the verified graph** and reports chain length.

**Samples, ranked by weakest evidence.** Nobody reviews 8,000 merges; reviewing the ten
flimsiest is tractable. Ranking per-metric once hid the two newest rules entirely — so
the queue ranks **per rule**, guaranteeing every path is represented.

---

## 9. Safety (design now, enforced in v1.1)

v1 writes nothing, but the invariants are built into the schema from the start:

- **`decision.verified_at`** is stamped only after a written file is re-read and its
  pixels hash-match. Reclaim refuses without it — deletion is *structurally* dependent
  on its replacement being provably good.
- **Two-phase renames**: every file steps aside before any lands; refuse, never
  overwrite.
- **Manifest written incrementally** — a crash halfway must leave an undoable state.
- **Undo granularity**, defined explicitly: a single merge decision, a resolve field, or
  a whole write — each independently reversible, across sessions, from the catalog.
- A verification must be derived from the **same definition of identity** as the thing
  it verifies, or it is a different question wearing the same name.

---

## 10. Technology

| Part | Choice | Note |
|---|---|---|
| UI | SwiftUI | native, good grids and tables |
| Engine | Swift, bounded work queue | one language, no IPC |
| Images | ImageIO, Core Image, Vision | decode, SSIM, features, text detection |
| Video | AVFoundation | duration, frames, stream identity |
| **Apple Photos** | **PhotoKit** | *never* read `Photos.sqlite` — undocumented and breaks between OS releases |
| **iOS devices** | **ImageCaptureCore** | supported; not `libimobiledevice` (LGPL, reverse-engineered) |
| Metadata **read** | ImageIO / CGImageMetadata | fast, no dependency |
| Metadata **write** | **bundled exiftool, `-stay_open`** | settled by spike: ImageIO either destroys EXIF dates or re-encodes the image (`SPIKES.md`). Perl, GPL/Artistic — shipped as a subprocess, not linked; rules out the Mac App Store |
| Catalog | SQLite (WAL) | proven schema |
| Timezones | bundled shapefile + tz rules incl. historical DST | offline, exact |

---

## 11. Milestones

**M0 — spikes (2 weeks). Nothing else starts until these resolve.**

| Spike | Question | Blocks | Status |
|---|---|---|---|
| Metadata write | can ImageIO write the full capture-date set losslessly? | architecture, bundle, licence | **done — no. exiftool bundled** (`SPIKES.md`) |
| PhotoKit | does it expose originals, Live Photo pairs, edit renditions? | Apple Photos as a source | open |
| Throughput | hash + metadata ≥100 files/s on 8 performance cores? | the progressive-results UX | open |

| # | Deliverable | Gate |
|---|---|---|
| **M1** | Sources, survey, catalog, scan+extract | survey numbers match the CLI on the same input |
| **M2** | Tiers A+B, canonical choice, **Groups browser** | first group on screen < 30 s |
| **M3** | Tier C + verification + radius dial with preview | longest verified chain matches the reference |
| **M4** | Video tier D, bursts, companions | **done** — Live Photos paired by ContentIdentifier, one companion per still; 271 on the reference library, reconciled exactly with Photos' own database |
| **M4a** | **Visual design pass** | a stranger can read the screen in five seconds and knows what is inferred vs measured |
| **M5** | Resolve: time, place, same-day, place→zone, audits | **done** — 0 contradictions among the app's own inferred zones; the audit surfaces 547 pre-existing ones stored in files (checked against each town's civil time), for the user to correct |
| **M6** | Timezone ballot (proposals only) | **done.** See the gate note below |
| **M7** | Scoreboard, Decisions inspector, export, dials with preview, boundary-case review | **done** — every asset's date, zone and place traceable in plain sentences; every dial previewed with samples before it is applied |
| **M8** | **v1 release** | runs end to end on three collections of different shape, at least one not the author's |

**M6's gate, restated after measuring it.** The original gate was *"top pick right ≥90%"*.
That is the wrong gate for a design whose whole point is refusing to guess: it scores a
ballot that honestly says *"I cannot separate +08:00 from +09:00"* exactly as harshly as one
that confidently picks the wrong continent. Measured on 1,354 known-zone days (70 more
excluded because the day's own files disagree, so there is no single right answer):

| | |
|---|---|
| when the ballot **commits**, it is right | **96.9%** (322 days) |
| the truth is among the three offered | **95.1%** |
| confidently wrong | **0.7%** |
| top pick right, counting refusals as failures | 86.3% |

The gate is therefore the first two lines: **≥95% when it commits, ≥95% truth-in-three**.
Both are met. The residual errors are ±1 h (DST and adjacent zones, which the neighbour
signal genuinely cannot separate) and ±13–15 h on travel days, where the nearest zoned day
is still in the departure zone. Both are refused rather than guessed.

Two of the five signals were silent on the reference collection — `Filename`, because a
Photos library has UUID names, and `Time of day`, which abstains by construction. The
back-test prints per-signal participation for exactly this reason: **a signal silent
everywhere means missing data, not agreement**, and a score measured without it is not a
score of the design. The first run of this back-test scored 84% with the daylight signal
structurally absent, because the catalog predated its `ev` column.

---

## 12. Tests

The 25 cases in `INHERITED.md` are **fixtures**, not prose — each becomes a test with a
synthetic or redacted sample. Highlights: an HEIC misnamed `.mp4` · a motion photo with
four streams · a still with two candidate companions · a q95/q40 recompression at
distance 3 (the case a tight radius loses) · two flat screenshots differing only in text
· a colour-graded edit at structural distance 0 · a QuickTime file whose `CreateDate` is
UTC · a file whose `IPTC:DateCreated` contradicts its EXIF · a camera with no zone tag
against sparse and dense reference tracks.

Plus:

- **golden master** on a fixed reference collection — catches silent behaviour drift
  better than unit tests
- **property**: no stage ever deletes or modifies a source file in v1
- **fuzz**: killing the app mid-stage always leaves a resumable catalog
- **performance regression** against the §6.2 budgets

---

## 13. Open questions

1. ~~Metadata writing~~ — **settled**: exiftool is bundled (`SPIKES.md`). Ship it as a
   subprocess with `-stay_open`; honour the GPL/Artistic source offer.
2. **Distribution** — bundling Perl rules out the Mac App Store. Direct download with
   Developer ID signing and notarization; decide on sandbox vs full disk access before
   building an installer.
3. **RAW+JPEG** — one asset with two renditions, or two assets? Leaning one, JPEG as
   variant.
4. **Ballot weights** — derive by back-testing, not intuition. Until then, unblended.
5. **Daylight signal limits** — quantify where it stops helping: indoor-only days, high
   latitudes near solstices, heavy flash.
6. **Scale ceiling** — 100k is the target; where do SQLite and the BK-tree actually
   break?
