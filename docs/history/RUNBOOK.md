# PhotoMerge — Runbook

The steps you run by hand, in order. `REQUIREMENTS.md` is the *what*, `PLAN.md` is
the *how*, this is the *do*.

## 0. Prerequisites

```bash
brew install exiftool                              # required
pip install pillow numpy pillow-heif opencv-python timezonefinder scikit-image
```

`exiftool` is non-negotiable — Python EXIF writers are unreliable for HEIC and MOV.
Everything else has a fallback. On this machine ffmpeg, brew and Python 3.13 are
already present; exiftool is the only thing missing.

---

## 1. Collect all three sources into a staging tree

```
~/PhotoMerge/
  mac/
  ipad/
  gphotos/
```

### 1a. Mac — `--exiftool` is the flag that matters

```bash
brew install osxphotos
osxphotos export ~/PhotoMerge/mac --download-missing --exiftool --touch-file
```

**Dates you corrected by hand inside the Photos app, and locations added after
import, live in the Photos database — not in the image files.** Without
`--exiftool` those edits are silently dropped on export, and no amount of
downstream cleverness can recover them. This is the single highest-stakes step in
the whole process.

`--download-missing` pulls originals that currently exist only in iCloud.

**Never reach into the `.photoslibrary` bundle directly** to grab files.

Loose photos elsewhere on disk: just copy them in.

### 1b. iPad — cable, not AirDrop

Connect by cable, open **Image Capture**, select all, import to `~/PhotoMerge/ipad/`.

Do **not** use AirDrop: the Photos share sheet can strip location depending on the
options toggle, and several thousand items over AirDrop will fail partway through.

### 1c. Google Photos

takeout.google.com → Google Photos only → export `.tgz` or `.zip` → extract to
`~/PhotoMerge/gphotos/`.

**Do not delete the `.json` files after extracting.** Capture time and GPS live in
those sidecars, not in the JPEG EXIF. They are the entire reason this tool can
recover locations the Mac copies never had.

Takeout is internally messy — the same photo commonly appears in both an album
folder and a `Photos from 2019/` folder. Normal; the dedup pass handles it.

### 1d. Optional — pre-process Takeout with GPTH Neo

Sidecar naming is fragile: current exports use
`IMG_1234.jpg.supplemental-metadata.json`, truncated at 51 characters, which breaks
naive matching.

- **Option A (default):** let PhotoMerge read the sidecars directly. It does fuzzy matching and pulls `photoTakenTime` and `geoData` out.
- **Option B:** if M0 reports a poor sidecar match rate, run **GooglePhotosTakeoutHelper_Neo** (`Xentraxx/GooglePhotosTakeoutHelper_Neo`) first and feed its output as the `gphotos` source.

Use the **Neo fork**, not the original — `TheLastGimbus/GooglePhotosTakeoutHelper`
has not been pushed since January 2025 with issues from 2026 still unanswered. Neo
is actively maintained and falls back to ExifTool when native EXIF parsing fails.

---

## 2. Survey first (M0)

```bash
python3 photomerge.py survey --src ~/PhotoMerge/mac --src ~/PhotoMerge/ipad --src ~/PhotoMerge/gphotos
```

Before tuning or merging anything, get the shape of the real data: counts by format,
EXIF coverage, **sidecar match rate**, duplicate estimate, burst estimate, oddities.
Every threshold below rests on assumptions this step either confirms or kills.

If the sidecar match rate is poor → go back to §1d Option B.

---

## 3. Dry run

```bash
python3 photomerge.py \
  --src ~/PhotoMerge/mac \
  --src ~/PhotoMerge/ipad \
  --src ~/PhotoMerge/gphotos \
  --out ~/PhotoMerge/RESULT \
  --dry-run
```

`--src` order is priority order — earlier sources win ties.

Read `photomerge_report.csv`:

| Column | What to check |
|---|---|
| `cluster_size` | Anything > 1 is a merge decision. Spot-check these. |
| `burst_collapsed` | How many frames were collapsed as bursts. Sanity-check the count against how much you actually burst-shoot. |
| `datetime_from` | `mtime(unreliable)` means the date is a guess. Count these. |
| `tz_resolved` | Times fixed by timezone reconciliation. Spot-check a few taken abroad. |
| `borrowed` | Which files needed metadata from a sibling, and from where. |
| `final_gps` | Empty means location is gone for good. Count these. |
| `review_reason` | Everything the tool refused to decide. Read all of these. |
| `dup_note` | Video duplicate hints for the manual pass. |

---

## 4. Calibrate the threshold

Default is dHash Hamming ≤ 6 — the single parameter most likely to be wrong for your
library.

- Many burst shots or similar compositions → lower to 3–4 (conservative)
- Many re-encoded or resized copies not being caught → raise to 8–10

**Use the contact sheets.** `photomerge verify --sample 20` tiles every member of 20
random multi-file clusters into scannable PNGs. Thirty seconds of looking beats an
hour of reading CSV rows, and it is the only way to build real confidence in the
threshold.

Re-running after a threshold change re-uses the catalog — hashes are not recomputed.

---

## 5. Real run

Drop `--dry-run`, add `--apply`. The tool copies (never moves), writes metadata with
exiftool, and leaves all three source trees untouched.

---

## 6. Verify before deleting anything

- [ ] Output count ≈ expected unique count; no catastrophic over-merge
- [ ] Contact-sheet sample of 20 clusters shows no false merges
- [ ] Burst collapses spot-checked — the kept frame is the sharp one
- [ ] 10 files spot-checked in `exiftool` — `DateTimeOriginal`, `OffsetTimeOriginal` and `GPSPosition` present
- [ ] A few photos taken abroad show the correct local time, not shifted by the offset
- [ ] Every `.MOV` in the dated folders has a same-stem image beside it
- [ ] `_VIDEOS/` count equals total real videos across all three sources — nothing lost
- [ ] A few outputs opened in Apple Photos or a map viewer land where expected
- [ ] Originals still present and untouched in `~/PhotoMerge/{mac,ipad,gphotos}`

**Keep the source trees for at least a month** before deleting. Disk is cheap; the
photos are not replaceable.

---

## 7. Pick a permanent home

1. **Import `RESULT/` into Apple Photos, turn on iCloud Photos.** The iPad syncs automatically and the three-way split never recurs. Costs iCloud storage.
2. **Keep it as a plain folder tree** plus a backup. Zero lock-in, zero automation.
3. **Self-host immich.** Open-source Google Photos replacement, but it is a server — only worth it to replace the whole cloud stack.

---

## 8. Keep an edge-case log

Every time a photo comes out wrong, write down **what shape of input caused it**, not
just the fix. Candidates: `-edited` suffix variants, truncated sidecar names, HEIC
without EXIF, screenshots with no capture time, photos from messaging apps with
stripped metadata, timezone drift on photos taken abroad, bursts that were not
recognised as bursts.

**This log is the actual asset.** If Phase 2 happens it is the thing nobody can get
without having done Phase 1 for real — and each entry becomes a fixture in the test
suite.
