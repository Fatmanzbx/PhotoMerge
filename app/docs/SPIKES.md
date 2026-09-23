# M0 spike results

Measured on macOS 27.0 / Swift 6.4 / SDK 27.0, Apple silicon, against real files from a
Photos library (Pixel 9 JPEG 4080×3072, iPhone HEIC).

---

## Spike 1 — Can ImageIO write the capture-date set without re-encoding?

**Answer: no. exiftool must be bundled.**

The requirement (`INHERITED §2.24`): write *every* capture-date field, because readers
disagree about precedence. And do it **losslessly** — a metadata edit that re-compresses
a JPEG is generational loss on every run.

Three approaches tested, same input, same target values:

| | pixels | EXIF dates | XMP | IPTC | GPS | `GPSProcessingMethod` |
|---|---|---|---|---|---|---|
| **A** `CGImageDestinationCopyImageSource` + `kCGImageDestinationMetadata` | **lossless** | **destroyed** | written | — | written | — |
| **B** `CGImageDestinationAddImageFromSource` + property dictionaries | **re-encoded** | written | **destroyed** | written | written | not written |
| **C** exiftool | **lossless** | written | preserved (9 tags) | written | written | written |

Decoded-pixel SHA-256, 4080×3072 JPEG:

```
in.jpg   0b46bfefc27561e2     source
A out    0b46bfefc27561e2     identical
B out    e88449db92b8bbd9     DIFFERENT — lossy re-encode
C out    0b46bfefc27561e2     identical
```

**Neither ImageIO path is usable.** A silently drops `ExifIFD:DateTimeOriginal` and
`CreateDate` — data loss, not merely an incomplete write. B re-encodes the image and
strips all 9 pre-existing XMP tags. Combining them is not possible in one pass: A
replaces metadata wholesale, so running it after B would undo B.

**Consequences, all now settled:**

- **exiftool is bundled.** It is the only thing that writes the full tag set losslessly.
- **Licence:** exiftool is Perl under GPL/Artistic. The app must ship it as a separate
  executable invoked as a subprocess — not linked — and its source offer must be
  honoured. Distribution stays outside the Mac App Store.
- **Performance:** exiftool starts a Perl interpreter per invocation. Use its
  `-stay_open` mode with a persistent process and a command pipe, as the CLI did.
- **ImageIO is still used** for *reading* metadata and for all decoding, where it is
  fast and dependency-free. Only writing goes through exiftool.

### Method note

The first pixel test was wrong and said both A and B re-encoded. It hashed `sips` PNG
output — but PNG carries metadata, so the hash differed whenever the metadata did. The
corrected test decodes to raw RGB and hashes the pixel buffer, which metadata cannot
affect. The A result (identical) validates that the instrument can detect sameness, so
the B result (different) is real.

This is `INHERITED §2.23` / `§2.25` again, inside the spike that was meant to de-risk
the build: **suspect the instrument first.**

---

## Spike 2 — PhotoKit as a source

*Not yet run.* Questions: does it expose originals (not renditions), Live Photo pairs,
edit renditions, and the `ContentIdentifier`? Blocks Apple Photos as an input.

---

## Spike 3 — Throughput

**Answer: target met. 126.7 files/s.**

Real work per file: mmap + SHA-256 of the whole file, ImageIO metadata read, and an
orientation-normalised 9×8 grayscale thumbnail reduced to a dHash. 1,000 real files from
a Photos library, Apple silicon, 10 performance + 4 efficiency cores.

| threads | files/s | note |
|---|---|---|
| 1 | 22.5 | comparable to the CLI's 27.7 single-threaded |
| 4 | 87.1 | |
| **10** | **126.7** | performance-core count — **best** |
| 14 | 117.8 | all logical cores — *slower* |

**Two design points confirmed empirically:**

- The **≥100 files/s** budget is achievable, so 100k assets extract in ~13 minutes and
  the progressive-results UX holds. First groups appear within seconds.
- **Size the work queue to performance cores, not `activeProcessorCount`.** Adding the
  4 efficiency cores cost 7% throughput. The plan asserted this; it is now measured.

Scaling is 5.6× on 10 cores (56% efficiency) — the remainder is I/O and ImageIO
decode serialisation, not lock contention. Good enough; not worth optimising before
there is a UI to feel it.

---

## Spike 4 — Can SwiftUI build without Xcode?

**Answer: no. Xcode is required** — though no Xcode *project* is.

The first probe said yes and was wrong. It built a SwiftUI app that used no property
wrappers. In current SDKs `@State`, `@StateObject` and `@EnvironmentObject` are
**macros**, and `libSwiftUIMacros.dylib` ships only with Xcode:

```
/Library/Developer/CommandLineTools/.../plugins/   libObservationMacros, libSwiftMacros
/Applications/Xcode.app/.../MacOSX.platform/.../plugins/   libSwiftUIMacros.dylib ✓
```

The real app therefore fails against the CLT with:

```
error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
```

**Resolution:** `build.sh` sets `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
and calls `xcrun swiftc`. Still no `.xcodeproj`, no `xcodebuild` — the bundle is
assembled by hand and the build stays one shell script. But Xcode must be installed and
**its licence accepted** (`sudo xcodebuild -license accept`), which is a documented
prerequisite for anyone building from source.

### Method note, again

The retest *also* reported success falsely: the build output was filtered with
`grep 'error:'`, and the licence refusal does not contain that string. Checking for the
absence of an error is not the same as checking for the presence of a binary. The
correct test is `[ -x "$BIN" ]`.

That is the fourth false reading in this project (`INHERITED §2.21, §2.23, §2.25`) and
the second inside the spikes meant to de-risk the build. The rule earns restating:
**verify the artefact, not the absence of a complaint.**
