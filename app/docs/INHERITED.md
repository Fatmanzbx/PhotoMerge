# Inherited constraints

Extracted from `../../docs/BUILDLOG.md` — the record of merging 25,471 real files into 10,796
photographs across two rounds. These are not suggestions. Each is a defect that reached
production in the CLI, and each is a **test fixture** for the app.

`PLAN.md` states these as plain rules rather than citations — a new contributor should
not have to follow footnotes to understand the design. This document is the index: the
evidence behind each rule, and the fixture list that keeps it enforced. The `§` numbers
map to `../../docs/BUILDLOG.md`, where each has the full story.

---

## The one-line version

| # | Constraint |
|---|---|
| §2.1 | Sidecars match by a ranked cascade, not name equality. `~N` is a copy marker, not an edit marker. |
| §2.2 | The extension lies. Read magic bytes; ISO-BMFF `ftyp` brands separate HEIC from MP4. |
| §2.3 | Google Motion Photos hold four streams; `-c copy` alone keeps the wrong one. |
| §2.4 | exiftool cannot create an Apple MakerNotes block — Live Photo pairing needs its own writer. |
| §2.5 | Batch timestamps are not capture times; downgrade a timestamp shared by many files. |
| §2.6 | A capture time can only be wrong *late*. Earliest plausible wins. |
| §2.7 | `QuickTime:CreateDate` is UTC by specification. |
| §2.8 | A wall clock must be re-anchored after its zone is found. |
| §2.9 | phash bit entropy cannot detect a flat image. Use grayscale stddev + tile MAE. |
| §2.10 | SSIM is unreliable on natural texture; needs a geometric fallback. |
| §2.11 | A still can draw two companions. One per still, decided by content id. |
| §2.12 | A movie absorbed into a Live Photo loses its filename — never reconcile by filename. |
| §2.13 | iCloud shared albums are a separate world; they cost no one storage. |
| §2.14 | Some hosts cannot obtain Automation permission; never depend on it silently. |
| §2.15 | A camera clock can be fitted against a phone's GPS track — when fixes are sparse. |
| §2.16 | A measured fix is also a timezone assertion. Only measured fixes may certify a zone, and an audit must never be fed its own output. |
| §2.17 | Which recorded field is authoritative decides whether filenames move. |
| §2.18 | A folder name is a trip name, not a per-photo location. |
| §2.19 | Nearest-in-time needs a travel bound, and a cheap assertion to notice when it fails. |
| §2.20 | A method needs a stated precondition, or it gets trusted where it cannot work. |
| §2.21 | Verifying *safe to delete* is where a merger actually risks the photographs. |
| §2.22 | Structural hashes are blind to a colour grade. |
| §2.23 | Do not measure free space immediately after deleting. |
| §2.24 | `EXIF:DateTimeOriginal` is not the only capture date, and not the one that wins. |
| §2.25 | Verify an import against the library's own database, in the library's own terms. |
| §3.1 | Pixel-tier yield is a property of the export tool, not the library. |
| §3.2 | The dHash radius is a recall/compute dial, **not** a safety dial. |

---

## The four that cost the most

**§3.2 — the radius.** Measured on *unverified* candidates, a naive transitive closure
chained 217 assets at radius 6, and the conclusion was "keep it tight". Verifying all
11,758 candidates and slicing by distance showed the longest chain is **6 at every
radius** — verification removes the explosion entirely. Radius 2 was *costing* real
duplicates: a q95-vs-q40 recompression sits at distance 3.

**§2.24 — capture-date precedence.** Writing `EXIF:DateTimeOriginal` is not enough. A
file with an editing history also carries `IPTC:DateCreated` and `XMP-xmp:CreateDate`,
which outrank it on import. Two frames shot five seconds apart landed two years apart in
the library. Write every field.

**§2.16 — zone certification.** Coordinates plus an instant determine an offset exactly,
which makes every measured fix a free audit of the offset resolved beside it — 411
contradictions found that way. But the same audit fed *inferred* locations returns 855,
because it has started confirming its own guesses.

**§2.21 / §2.23 / §2.25 — suspect the instrument.** Three alarms, all false, all the
checker's fault: 214 videos "missing" under a hash test the design explicitly forbids;
33 GB "unreclaimed" that APFS had simply not freed yet; 843 photographs "misdated" by a
query that ignored each asset's own stored zone. The tell is scale — if a defect would
have to have been introduced by a step that touched far fewer files than the number now
failing, it is almost always a bad check.

---

## Fixtures to build first

- a Takeout exercising every sidecar collision convention
- an HEIC misnamed `.mp4`, and the reverse
- a motion photo with four streams
- a still with two candidate companions
- byte-identical pixels in differently-written files
- a q95/q40 recompression pair at distance 3
- two flat screenshots differing only in their text
- a colour-graded edit at structural distance 0
- a QuickTime file whose `CreateDate` is UTC
- a file whose `IPTC:DateCreated` contradicts its `EXIF:DateTimeOriginal`
- a camera with no zone tag, against a sparse track and a dense one
- a rename that would land on an occupied path
