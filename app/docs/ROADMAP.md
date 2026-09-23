# Roadmap — after v1

`PLAN.md` ships an analyser that writes nothing. Everything here is deferred
deliberately, not forgotten. Each item says **why it waits** and **what must be true
before it starts**.

---

## v1.1 — Act  ·  **built into v1** (see README, "A merged copy")

**Write a clean output tree.** Originals untouched; the tree is a new copy.

```
YYYY/MM/YYYYMMDD_HHMMSS.ext      collision suffix _N      variants _edited
```

Writing metadata sets **every** capture-date field — `EXIF:DateTimeOriginal`,
`EXIF:CreateDate`, `XMP-xmp:CreateDate`, `XMP-photoshop:DateCreated`,
`IPTC:DateCreated`/`TimeCreated`. Readers disagree about precedence, and a file with an
editing history carries tags that outrank the EXIF pair: two frames taken five seconds
apart once landed two years apart for exactly this reason. `IFD0:ModifyDate` is left
alone — it means *last modified*.

Every written file is re-read and pixel-hashed before `verified_at` is stamped.

**Requires:** M0 metadata-write spike resolved; two-phase rename; incremental manifest;
undo proven by test.

**Why it waits:** the analyser has to be trusted before anyone accepts a second copy of
their library.

---

## v1.2 — Reclaim

Unlink duplicates, gated on `decision.verified_at`. Staged first, unlinked only on
explicit confirmation, with a restore path until the stage is cleared.

**Requires:** v1.1 shipped and used on real collections; undo across sessions.

**Why it waits:** this is the only irreversible thing the app does.

---

## v1.3 — Incremental

"I dumped my phone again." Re-scan changed sources, merge only what is new, keep every
prior decision. The rounds design already supports it; this is the UX.

**Requires:** stable catalog schema across versions.

---

## v2 — Apple Photos

**Import** the output tree into Photos, or annotate a Photos library in place via
PhotoKit.

Reconcile by arithmetic — `live×2 + singles == files` — **never by filename**: a movie
absorbed into a Live Photo takes the still's name, which makes filename reconciliation
report phantom losses.

**Live Photo pairing** needs a shared Apple `ContentIdentifier`. exiftool cannot create
the Apple MakerNotes block, so the app must write it itself. Understood but
undocumented — needs a spike and a validation harness, and must be validated on a
handful of pairs before running all of them.

**Why it waits:** highest-risk undocumented surface in the whole product.

---

## v2 — Rounds

An output tree becomes a later input. `resolve --prior <catalog>` resolves from what the
sources originally claimed rather than from a previous round's embedded conclusions.

The subtle part, learned the hard way: **once a round writes its conclusions into files,
the next round reads them back as ordinary camera metadata** and cannot distinguish them
from measurement. Anything a later round must be able to override has to live in the
catalog, not only in the file.

---

## v2 — Camera-clock fitting

A camera with no zone tag, fitted against a device that carries measured fixes: for
shift `s`, minimise `median_j min_i |w_j − s − t_i|`.

Report the **shape** of the objective, not just its minimum. With dense reference fixes
every shift scores well and the method must refuse to answer — on one real trip, +1h,
+11h, −5h and −8h all scored within 2 minutes of each other. Offer to apply only a
sharp, unique minimum.

**Why it waits:** needs a second device with fixes from the same trip. Niche, and the
timezone ballot (v1) covers the common case.

---

## Later, maybe

| | |
|---|---|
| **Other libraries** | Lightroom, Capture One — read catalogs, propose, never write |
| **Shared collections** | two people merging into one: whose rules win? Schema should not preclude it |
| **Video dedup depth** | scene-level matching for differently-trimmed exports |
| **Sidecar edits** | Lightroom `.xmp` as a rendition rather than a duplicate |
| **Face-based grouping** | only as a *browsing* aid, never in the identity path |

---

## Explicitly never

- **Network anything.** No sync, no backup service, no telemetry, no licence check, no
  model download. The offline guarantee is structural — no network stack is linked — and
  that is worth more than any feature on this page.
- **LLM in the identity path.** A wrong merge is unrecoverable. Every merge must trace
  to a rule a person can read.
- **Editing pixels.** Adjacent problem, different product.
- **Deleting anything the user has not seen explained.**
