# PhotoMerge

<img src="app/Resources/AppIcon-1024.png" width="112" align="right" alt="PhotoMerge icon">

**Tidy a photo collection that has ended up in too many places** — a Mac, an iPad, a
Google Takeout, old backup drives — into one clean library: every photo exactly once,
the best copy of each, with the right date, time zone and place written into it.

PhotoMerge runs entirely on your Mac. It never connects to the internet, never changes
the files you give it, and every choice it makes — or you make — can be undone.

## What it does

- **Finds duplicates, safely.** Byte-identical files, re-saves, resized and recompressed
  copies — each candidate is checked against the pixels at two resolutions and the moment
  it was taken, so burst frames and look-alikes are never merged. Edited copies (a crop, a
  filter) are shown to you, not merged behind your back.
- **Works out when and where.** It reads EXIF, video metadata, Google Takeout sidecars
  and dates in filenames; fills gaps from photos taken nearby that day; derives time zones
  exactly where a clock and an instant agree; and flags photos whose recorded time zone
  contradicts where they were taken. Anything estimated is marked as such.
- **Pairs Live Photos** by Apple's content identifier, so a still and its clip stay one
  photo.
- **Lets you fill in the rest** — select many photos at once and give them a day and a
  place (a city name or coordinates), offline.
- **Saves the result** as a new, verified library (`2019/07/20190714_120000.jpg`, every
  date field written, each file read back and checked against its original), or tidies in
  place by moving extra copies to the Trash, where they can be put back.

## Download and install

Get `PhotoMerge-<version>.dmg` from the **[latest release](../../releases/latest)**, open
it and drag PhotoMerge into Applications. The first time, right-click the app and choose
**Open** (it is not signed with a paid Apple certificate). macOS 14 or newer, Apple silicon
or Intel.

**[Install and use →](docs/GUIDE.md)** walks through the four steps.

## Repository

| | |
|---|---|
| [`app/`](app/) | **PhotoMerge.app**, the macOS app (Swift, SwiftUI). Start here. |
| [`docs/GUIDE.md`](docs/GUIDE.md) | Install and use: the four steps, what each button does, what the app never does. |
| [`app/docs/`](app/docs/) | Its design: plan, roadmap, the lessons it inherited, and technical spikes. |
| [`cli/`](cli/) | The original command-line tool (Python) the app grew out of, with its tests. |
| [`docs/BUILDLOG.md`](docs/BUILDLOG.md) | The story of the first real merge — 25,471 files — and every edge case it hit. |
| [`docs/history/`](docs/history/) | The first requirements and plans, and the v0 script. |

## Build and run

```sh
brew install exiftool
cd app
./build.sh        # → build/PhotoMerge.app
./test.sh         # engine tests, headless
open build/PhotoMerge.app
./make_dmg.sh 1.0.0   # a universal build for macOS 14+ and dist/PhotoMerge-1.0.0.dmg
```

Requires macOS 14 or later and Xcode (for SwiftUI's macro plugin). See
[`app/README.md`](app/README.md) for how it works inside.

## Principles

- **Your originals are never modified.** Results go to a new folder you choose, or extra
  copies go to the Trash — never anything inside a Photos library, which would damage it.
- **Read beats estimated, and estimated says so.** A guess that looks like a measurement is
  worse than a gap.
- **When the evidence can't decide, you do** — and every decision can be taken back (⌘Z).
- **Offline.** No network, no cloud service, no AI model. Place names come from a list
  inside the app.

## Credits

- Place names: [GeoNames](https://www.geonames.org), licensed under
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) (`app/Resources/places.tsv`,
  built by `app/Tools/make_places.py`).
- Writing metadata: [ExifTool](https://exiftool.org) by Phil Harvey, under the Perl
  licence (GPL or Artistic). It is not in this repository; `build.sh` copies an installed
  ExifTool into the app, unmodified, where it runs as a separate program.

## License

MIT — see [`LICENSE`](LICENSE). Third-party data and tools keep their own licences, above.
