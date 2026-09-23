"""One long-lived exiftool process, fed batches.

Pillow misses HEIC and MOV tags and all MakerNotes (D12), and spawning exiftool
per file costs more than reading the file.  `-stay_open` plus an explicit tag
list keeps the whole extract to a single child process.

The child runs with `TZ=UTC`.  QuickTime stores creation dates in UTC and
exiftool renders them in the *machine's* zone; without this the catalog would
depend on where the merge was run, which is the root of D2.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

# Everything stage 4 can reason about, and nothing else: MakerNotes blobs make
# the JSON an order of magnitude larger for no gain.
TAGS = [
    "-EXIF:DateTimeOriginal", "-EXIF:CreateDate", "-EXIF:ModifyDate",
    "-EXIF:OffsetTime", "-EXIF:OffsetTimeOriginal", "-EXIF:OffsetTimeDigitized",
    "-EXIF:GPSLatitude", "-EXIF:GPSLongitude", "-EXIF:GPSAltitude",
    "-EXIF:GPSDateStamp", "-EXIF:GPSTimeStamp",
    "-EXIF:Make", "-EXIF:Model", "-EXIF:LensModel", "-EXIF:Orientation",
    "-EXIF:ExposureTime", "-EXIF:FNumber", "-EXIF:ISO",
    "-EXIF:ImageWidth", "-EXIF:ImageHeight",
    "-EXIF:ExifImageWidth", "-EXIF:ExifImageHeight",
    "-File:ImageWidth", "-File:ImageHeight", "-File:FileType", "-File:MIMEType",
    "-Composite:GPSLatitude", "-Composite:GPSLongitude", "-Composite:GPSAltitude",
    "-Composite:SubSecDateTimeOriginal", "-Composite:ImageSize", "-Composite:Rotation",
    "-XMP:DateCreated", "-XMP:CreateDate", "-XMP:GPSLatitude", "-XMP:GPSLongitude",
    "-XMP:Description", "-XMP:Title", "-XMP:Rating", "-XMP:Subject",
    "-XMP:MotionPhoto", "-XMP:MotionPhotoVersion", "-XMP:MicroVideoOffset",
    "-QuickTime:CreateDate", "-QuickTime:CreationDate", "-QuickTime:ModifyDate",
    "-QuickTime:MediaCreateDate", "-QuickTime:GPSCoordinates",
    "-QuickTime:Make", "-QuickTime:Model", "-QuickTime:ImageWidth",
    "-QuickTime:ImageHeight", "-QuickTime:Duration", "-QuickTime:Rotation",
    "-Keys:CreationDate", "-Keys:GPSCoordinates", "-Keys:Make", "-Keys:Model",
    "-UserData:GPSCoordinates",
    "-MakerNotes:ContentIdentifier", "-QuickTime:ContentIdentifier",
    "-Keys:ContentIdentifier", "-QuickTime:LivePhotoAuto",
]

OPTIONS = [
    "-j",                      # JSON out
    "-G",                      # group-qualified keys, so EXIF and QuickTime stay apart
    "-n",                      # numeric: signed GPS, numeric Orientation and ExposureTime
    "-api", "QuickTimeUTC=1",
    "-api", "LargeFileSupport=1",
    "-charset", "filename=utf8",
    "-m",                      # ignore minor errors rather than abort a batch
]


class ExifToolMissing(RuntimeError):
    pass


class ExifTool:
    """`exiftool -stay_open` driven over a pipe."""

    def __init__(self, executable: str = "exiftool") -> None:
        found = shutil.which(executable)
        if not found:
            raise ExifToolMissing(
                "exiftool not found — `brew install exiftool` (README §0). "
                "It is required: Python EXIF writers are unreliable for HEIC and MOV."
            )
        env = dict(os.environ, TZ="UTC")
        self._proc = subprocess.Popen(
            [found, "-stay_open", "True", "-@", "-"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=env,
        )

    def read(self, paths: list[Path]) -> dict[str, dict]:
        """Tag dicts keyed by the path as given.  Unreadable files are absent."""
        if not paths:
            return {}
        args = [*OPTIONS, *TAGS, *(str(p) for p in paths), "-execute\n"]
        payload = "\n".join(args).encode()
        assert self._proc.stdin and self._proc.stdout
        self._proc.stdin.write(payload)
        self._proc.stdin.flush()

        chunks: list[bytes] = []
        while True:
            line = self._proc.stdout.readline()
            if not line:
                raise RuntimeError("exiftool exited unexpectedly")
            if line.strip() == b"{ready}":
                break
            chunks.append(line)
        try:
            records = json.loads(b"".join(chunks) or b"[]")
        except ValueError:
            return {}
        return {r.get("SourceFile", ""): r for r in records}

    def write(self, jobs: list[tuple[Path, list[str]]]) -> tuple[int, str]:
        """Apply tag arguments to files. Returns `(files_updated, output)`.

        `-overwrite_original` edits in place, which is what we want: the file was
        already copied to its destination, and rewriting the metadata block does
        not touch the compressed image data.
        """
        if not jobs:
            return 0, ""
        args: list[str] = []
        for path, tags in jobs:
            args.extend(tags)
            args.append("-overwrite_original")
            args.append("-api")
            args.append("LargeFileSupport=1")
            args.append("-charset")
            args.append("filename=utf8")
            args.append("-m")
            args.append(str(path))
            args.append("-execute")
        assert self._proc.stdin and self._proc.stdout
        self._proc.stdin.write(("\n".join(args) + "\n").encode())
        self._proc.stdin.flush()

        updated, lines, seen = 0, [], 0
        while seen < len(jobs):
            line = self._proc.stdout.readline()
            if not line:
                raise RuntimeError("exiftool exited unexpectedly")
            text = line.decode(errors="replace").strip()
            if text == "{ready}":
                seen += 1
                continue
            lines.append(text)
            if "image files updated" in text:
                updated += int(text.split()[0])
        return updated, "\n".join(lines)

    def close(self) -> None:
        if self._proc.poll() is None and self._proc.stdin:
            try:
                self._proc.stdin.write(b"-stay_open\nFalse\n")
                self._proc.stdin.flush()
            except OSError:
                self._proc.kill()
            try:
                self._proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self._proc.kill()

    def __enter__(self) -> ExifTool:
        return self

    def __exit__(self, *exc) -> None:
        self.close()
