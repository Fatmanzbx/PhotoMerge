# PhotoMerge — install and use

PhotoMerge tidies a photo collection on your Mac: it finds duplicate copies, keeps the
best one, works out when and where each photo was taken, and saves a clean library.
Everything runs on your Mac. Nothing is uploaded, and your original files are never
modified.

## Install

**Requirements:** a Mac with Apple silicon (M1 or later) or Intel, running macOS 14
Sonoma or newer. About 20 MB of disk for the app; a clean library needs as much free
space as the photos you keep.

1. Download `PhotoMerge-<version>.dmg` from the
   [latest release](../../releases/latest).
2. Open the `.dmg` and drag **PhotoMerge** into **Applications**.
3. The first time, **right-click PhotoMerge → Open**, then click **Open** in the
   dialog. macOS shows this warning because the app is not signed with a paid Apple
   developer certificate; it is only needed once.

   If macOS says the app "is damaged and can't be opened", it has quarantined the
   download. Remove the flag in Terminal and open it again:

   ```sh
   xattr -d com.apple.quarantine /Applications/PhotoMerge.app
   ```

4. When PhotoMerge first reads your Photos library, macOS asks for permission to
   access your Pictures folder. Allow it, or the app will find no files.

To build it yourself instead, see the [README](../README.md#build-and-run).

## Use

The window is one flow, four steps across the top. You can move between steps 2 and 3
freely and as often as you like; Save opens once every photo has a date and a place,
or you have chosen to leave the rest as they are. Everything you decide can be undone
with ⌘Z, and nothing on disk changes until step 4.

### 1 · Add photos

Drag folders into the window, click **Choose folders…**, or click **Add my Photos
library**. Add as many as you like: a Google Takeout, an old backup drive, a folder of
phone photos. Reading starts at once and results appear as it goes; you can quit at
any time and it carries on where it stopped.

To skip part of a folder (a "Screenshots" subfolder, `*.png`), click **Exclude…** on
that folder.

### 2 · Duplicates

Every photo the app has more than one copy of, with the copy it keeps marked **KEEP**
and the reason. The kept copy is the one with the most pixels, then the largest file,
and it takes its date, time zone and place from all its copies together, so nothing
known about a photo is lost with the extras.

- Open a group to see why, or press **1–9** to keep a different copy; **space**
  compares two copies side by side.
- **How alike is a duplicate?** sets how loosely photos are matched. Every setting is
  tried on your photos first, with a table of what it would merge and samples of the
  closest calls, before you apply it.
- **Edited copies** are one shot, edited: the same instant and frame, but a different
  crop, colour or exposure. The app never merges these on its own; say *same* or
  *different* for each, or **Keep them all as separate photos**.

### 3 · Time & place

The header says how many photos still need a date or a place. Two views:

**Worked out for you** shows what the app found on its own and the few things it puts
to you:

- Rings for how many photos have a date, a time zone and a place.
- **Places worked out, by area.** Photos without GPS whose place was taken from photos
  of the same day, a photo near in time, or the same folder, gathered by area
  (50 km). Look through an area; if a few are wrong, give them their real place under
  *Fill in by hand* first (they leave the area), then **Accept all** for the rest.
- **Checks.** Photos whose time zone cannot be right — clocks at that place showed a
  different zone at that moment. **Correct** keeps the moment and fixes the clock.
- **Which time zone was each day?** Days with a clock but no zone and no way to tell;
  the app lists what the evidence implies and you choose, or leave it.
- Two sliders for how far a photo without GPS may borrow a place, previewed before you
  apply them.

**Fill in by hand** is a grid of every photo that still needs a date or a place, and
of those with a worked-out place. Select many at once — click, ⌘-click, ⇧-click, or
drag a box — then give them a day, a place (a city name such as "Lisbon" or "東京", or
coordinates), or both, and click **Apply**. A date or GPS a file records is never
replaced; a worked-out place is.

When what is left cannot be known, click **Leave the rest as they are**. Save opens.

### 4 · Save

- **Save a clean library** writes a new folder you choose: one file per photo, named
  `YYYY/MM/YYYYMMDD_HHMMSS.ext`, duplicates left out, Live Photo clips beside their
  stills, and the dates, time zones and places written into each file. Every file is
  read back and checked against its original before it counts as written. Photos
  without a date go under `Undated/`, keeping their names. Your originals stay exactly
  as they are; **Undo** removes only files still exactly as written.
- **Tidy in place** moves the extra copies to the Trash, where you can put them back
  (from the app, with ⌘Z, or from the Trash itself). A copy is moved only if the one
  kept is still there and unchanged. Nothing inside a Photos library is touched;
  save a clean library instead.

### Everything else

**All panes** (top right, or ⌥⌘A) shows the same app with a sidebar: the reasoning
behind any photo's date and place (*Decisions*), the timeline, place rules, exports and
settings. **Back to steps** at the top of the sidebar returns to the flow.

**Help** in the Help menu explains each screen. **File → Export Findings…** writes a
CSV of every photo with its date, zone, place and how each was arrived at.

## What it never does

- It never modifies, moves or deletes a file unless you choose *Save*, and then only
  the copies it made, or duplicates to the Trash.
- It never connects to the internet. Place names come from a bundled list of 34,000
  towns; time zones from macOS.
- It never guesses a time zone without telling you: a date it cannot place in a zone
  is shown as such and put to you.
