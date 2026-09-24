#!/usr/bin/env python3
"""Generate a synthetic photo library whose right answers are known.

    Tests/known_library.py <out-folder>

Every image is drawn here — no real photographs are used — and each case records
what PhotoMerge must conclude about it in <out-folder>/truth.json. Needs Pillow,
exiftool and ffmpeg. Scored by Tests/check_known.py.
"""
import json, os, random, shutil, subprocess, sys, time, calendar
from pathlib import Path
try:
    from PIL import Image, ImageDraw, ImageEnhance
except ImportError:
    sys.exit("python3 with Pillow is needed (pip install pillow); the library is drawn with it")
for tool in ("exiftool", "ffmpeg", "sips"):
    if not shutil.which(tool): sys.exit(f"{tool} is needed on PATH (brew install exiftool ffmpeg)")

OUT = Path(sys.argv[1]).resolve()
if OUT.exists(): shutil.rmtree(OUT)
OUT.mkdir(parents=True)
truth = {"cases": []}

LIS = (38.7251, -9.1498)     # winter offset +00:00
TYO = (35.6895, 139.6917)    # +09:00
NYC = (40.7128, -74.0060)    # winter offset -05:00

def scene(seed, w=1024, h=768, shift=0):
    """A distinct 'landscape': sky gradient, hills, shapes, fine texture."""
    r = random.Random(seed)
    im = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(im)
    top = [r.randrange(40, 200) for _ in range(3)]; bot = [r.randrange(40, 220) for _ in range(3)]
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] * (1 - t) + bot[i] * t) for i in range(3)))
    for _ in range(4):
        pts = [(0, h)] + [(x, r.randrange(h // 3, h)) for x in range(0, w + 1, w // r.randrange(3, 7))] + [(w, h)]
        d.polygon(pts, fill=tuple(r.randrange(20, 200) for _ in range(3)))
    for _ in range(7):
        x, y, s = r.randrange(w), r.randrange(h), r.randrange(30, 160)
        d.ellipse([x + shift, y, x + s + shift, y + s], fill=tuple(r.randrange(256) for _ in range(3)))
    px = im.load(); nr = random.Random(seed * 7 + 1)
    for _ in range(w * h // 12):
        x, y = nr.randrange(w), nr.randrange(h); c = px[x, y]; v = nr.randrange(-18, 18)
        px[x, y] = tuple(max(0, min(255, k + v)) for k in c)
    return im

def save(img, rel, quality=92):
    p = OUT / rel; p.parent.mkdir(parents=True, exist_ok=True)
    img.save(p, "JPEG", quality=quality); return p

def exif(rel, when=None, offset=None, gps=None):
    args = ["exiftool", "-q", "-overwrite_original"]
    if when: args += [f"-EXIF:DateTimeOriginal={when}", f"-EXIF:CreateDate={when}"]
    if offset: args += [f"-EXIF:OffsetTimeOriginal={offset}"]
    if gps:
        la, lo = gps
        args += [f"-GPSLatitude={abs(la)}", f"-GPSLatitudeRef={'N' if la >= 0 else 'S'}",
                 f"-GPSLongitude={abs(lo)}", f"-GPSLongitudeRef={'E' if lo >= 0 else 'W'}"]
    subprocess.run(args + [str(OUT / rel)], check=True)

def sidecar(rel_json, utc, gps=None, title=None):
    ts = calendar.timegm(time.strptime(utc, "%Y-%m-%d %H:%M:%S"))
    o = {"photoTakenTime": {"timestamp": str(ts)}}
    if gps is not None: o["geoDataExif"] = {"latitude": gps[0], "longitude": gps[1], "altitude": 0}
    if title: o["title"] = title
    p = OUT / rel_json; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(json.dumps(o))

def video(rel, seconds, seed):
    p = OUT / rel; p.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                    f"testsrc2=size=640x360:rate=24:duration={seconds}",
                    "-vf", f"hue=h={seed * 37 % 360}", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(p)], check=True)

def case(name, **expect): truth["cases"].append({"name": name, **expect})

# 1. exact copies (one inside a camera's storage folder, which is not an album)
save(scene(1), "DCIM/100APPLE/IMG_0001.JPG"); exif("DCIM/100APPLE/IMG_0001.JPG", "2021:01:10 10:00:00", "+00:00", LIS)
(OUT / "Backup").mkdir(); shutil.copy(OUT / "DCIM/100APPLE/IMG_0001.JPG", OUT / "Backup/IMG_0001.JPG")
case("exact copies are one photo", same=["DCIM/100APPLE/IMG_0001.JPG", "Backup/IMG_0001.JPG"],
     output={"DCIM/100APPLE/IMG_0001.JPG": "2021/01/20210110_100000.jpg"})

# 2. re-encodes: the full-size q92 is kept
save(scene(2), "Tokyo/IMG_0002.jpg"); exif("Tokyo/IMG_0002.jpg", "2021:01:20 12:05:00", "+09:00", TYO)
im = Image.open(OUT / "Tokyo/IMG_0002.jpg")
save(im, "Phone export/IMG_0002 q55.jpg", 55)
save(im.resize((512, 384), Image.LANCZOS), "Phone export/IMG_0002 small.jpg", 85)
for r_ in ["Phone export/IMG_0002 q55.jpg", "Phone export/IMG_0002 small.jpg"]:
    subprocess.run(["exiftool", "-q", "-overwrite_original", "-tagsFromFile", str(OUT / "Tokyo/IMG_0002.jpg"), "-all:all", str(OUT / r_)], check=True)
case("re-encodes merge and the full-size copy is kept",
     same=["Tokyo/IMG_0002.jpg", "Phone export/IMG_0002 q55.jpg", "Phone export/IMG_0002 small.jpg"],
     canonical="Tokyo/IMG_0002.jpg")

# 3. a burst: one second apart, never merged
save(scene(3), "Lisbon/burst_1.jpg"); exif("Lisbon/burst_1.jpg", "2021:01:10 16:00:00", "+00:00", LIS)
save(scene(3, shift=6), "Lisbon/burst_2.jpg"); exif("Lisbon/burst_2.jpg", "2021:01:10 16:00:01", "+00:00", LIS)
case("burst frames stay separate", separate=[["Lisbon/burst_1.jpg", "Lisbon/burst_2.jpg"]])

# 4. an edited copy: same shot, brighter — put to the person, not merged
save(scene(4), "Lisbon/sunset.jpg"); exif("Lisbon/sunset.jpg", "2021:01:10 17:00:00", "+00:00", LIS)
save(ImageEnhance.Brightness(Image.open(OUT / "Lisbon/sunset.jpg")).enhance(1.3), "Lisbon/sunset edited.jpg")
exif("Lisbon/sunset edited.jpg", "2021:01:10 17:00:00", "+00:00", LIS)
case("an edited copy is asked about, not merged", separate=[["Lisbon/sunset.jpg", "Lisbon/sunset edited.jpg"]],
     pair={"files": ["Lisbon/sunset.jpg", "Lisbon/sunset edited.jpg"], "outcome": "variant"})

# 5. same day, same place
save(scene(5), "Lisbon/L1.jpg"); exif("Lisbon/L1.jpg", "2021:01:10 11:00:00", "+00:00", LIS)
save(scene(6), "Lisbon/L2.jpg"); exif("Lisbon/L2.jpg", "2021:01:10 14:00:00", "+00:00", (LIS[0] + 0.002, LIS[1]))
save(scene(7), "Lisbon/L3 no gps.jpg"); exif("Lisbon/L3 no gps.jpg", "2021:01:10 12:30:00", "+00:00")
case("a photo without GPS takes its day's place", place={"Lisbon/L3 no gps.jpg": "same day, same place"},
     near={"Lisbon/L3 no gps.jpg": LIS})

# 6. Takeout: sidecar only, both collision conventions, an edit of its origin, (0,0)
T = "Takeout/Google Photos/Photos from 2021/"
save(scene(8), "NY/NY tagged.jpg"); exif("NY/NY tagged.jpg", "2021:01:05 09:00:00", "-05:00", NYC)
save(scene(9), T + "IMG_0088 (1).jpeg"); sidecar(T + "IMG_0088 (1).jpeg.supplemental-metadata.json", "2021-01-05 15:00:00", NYC)
save(scene(10), T + "IMG_0899(1).jpg"); sidecar(T + "IMG_0899.jpg.supplemental-metadata(1).json", "2021-01-20 04:00:00", TYO)
save(scene(11), T + "PXL_20210105_160000000.jpg"); sidecar(T + "PXL_20210105_160000000.jpg.supplemental-metadata.json", "2021-01-05 16:00:00", NYC)
save(ImageEnhance.Contrast(Image.open(OUT / (T + "PXL_20210105_160000000.jpg"))).enhance(1.6), T + "PXL_20210105_160000000-edited.jpg")
save(scene(12), T + "IMG_0100.jpg"); sidecar(T + "IMG_0100.jpg.supplemental-metadata.json", "2021-02-10 09:00:00", (0.0, 0.0))
case("a sidecar dates and places a bare photo, zoned by where it was taken",
     time={T + "IMG_0088 (1).jpeg": ["2021:01:05 10:00:00", "-05:00", "Takeout sidecar"]},
     place={T + "IMG_0088 (1).jpeg": "sidecar GPS"}, sidecar_rule={T + "IMG_0088 (1).jpeg": "exact"})
case("the collision number on the sidecar is found",
     time={T + "IMG_0899(1).jpg": ["2021:01:20 13:00:00", "+09:00", "Takeout sidecar"]},
     sidecar_rule={T + "IMG_0899(1).jpg": "collision"})
case("an edit inherits its origin's sidecar", sidecar_rule={T + "PXL_20210105_160000000-edited.jpg": "edit of origin"},
     time={T + "PXL_20210105_160000000-edited.jpg": ["2021:01:05 11:00:00", "-05:00", None]})
case("(0,0) is no location, and a lone instant is never given a zone",
     place={T + "IMG_0100.jpg": "none"},
     time={T + "IMG_0100.jpg": ["2021:02:10 09:00:00", None, "Takeout sidecar, shown in UTC"]})

# 7. a local clock plus a sidecar instant is the time zone
save(scene(13), T + "IMG_2001.jpg"); exif(T + "IMG_2001.jpg", "2021:01:20 14:00:00", None, None)
sidecar(T + "IMG_2001.jpg.supplemental-metadata.json", "2021-01-20 05:00:00")
case("a clock and an instant give the zone exactly",
     zone={T + "IMG_2001.jpg": ["+09:00", "clock + Takeout sidecar instant"]})

# 8. a Pixel filename is UTC; its zone comes from the nearest photo in time
save(scene(14), "Tokyo/T0 noon.jpg"); exif("Tokyo/T0 noon.jpg", "2021:01:20 12:00:00", "+09:00", TYO)
save(scene(15), "Phone/PXL_20210120_023000000.jpg")
case("a Pixel name is read as UTC and zoned by its neighbour",
     time={"Phone/PXL_20210120_023000000.jpg": ["2021:01:20 11:30:00", "+09:00", "Pixel filename (UTC)"]},
     zone={"Phone/PXL_20210120_023000000.jpg": ["+09:00", "nearest photo in time"]})

# 9. a filename wall clock beats the file date
save(scene(16), "Phone/IMG_20210201_083015.jpg")
case("an IMG_ name is a local clock", time={"Phone/IMG_20210201_083015.jpg": ["2021:02:01 08:30:15", None, "filename"]})

# 10. nothing at all: file date only, and saved under its own name
p = save(scene(17), "Scans/scan_0001.jpg"); ts = calendar.timegm((2020, 6, 1, 12, 0, 0)); os.utime(p, (ts, ts))
case("a photo with only a file date goes to Undated", timesource={"Scans/scan_0001.jpg": "mtime (unreliable)"},
     output={"Scans/scan_0001.jpg": "Undated/scan_0001.jpg"})

# 11. the wrong time zone, contradicted by the photos around it
for i, m in enumerate(["00", "10", "20"]):
    save(scene(20 + i), f"Tokyo/day2_{i}.jpg"); exif(f"Tokyo/day2_{i}.jpg", f"2021:01:22 12:{m}:00", "+09:00", TYO)
save(scene(23), "Tokyo/day2_wrong.jpg"); exif("Tokyo/day2_wrong.jpg", "2021:01:21 19:15:00", "-08:00", TYO)
case("a contradicted time zone is caught", audit={"Tokyo/day2_wrong.jpg": "+09:00"},
     noaudit=["Tokyo/day2_0.jpg"])

# 12. a folder that is one place, and one that is a trip
bg = (38.7179, -9.1500)
for i in range(3):
    save(scene(30 + i), f"Botanic Garden/g{i}.jpg"); exif(f"Botanic Garden/g{i}.jpg", f"2021:03:0{i + 1} 10:00:00", "+00:00", (bg[0] + i * 0.0005, bg[1]))
save(scene(33), "Botanic Garden/g bare.jpg"); exif("Botanic Garden/g bare.jpg", "2021:03:09 10:00:00", "+00:00")
for i, (c, off) in enumerate([(LIS, "+01:00"), (TYO, "+09:00"), (NYC, "-04:00")]):
    save(scene(40 + i), f"Grand Tour/t{i}.jpg"); exif(f"Grand Tour/t{i}.jpg", f"2021:04:0{1 + 4 * i} 10:00:00", off, c)
save(scene(43), "Grand Tour/t bare.jpg"); exif("Grand Tour/t bare.jpg", "2021:04:12 10:00:00", "+01:00")
case("a folder whose photos agree names a place; a trip folder does not",
     place={"Botanic Garden/g bare.jpg": "same folder, same place", "Grand Tour/t bare.jpg": "none"})

# 13. Live Photo by name: a short clip pairs, a long video with the same name does not
save(scene(50), "Live/IMG_3001.JPG"); exif("Live/IMG_3001.JPG", "2021:01:10 18:00:00", "+00:00", LIS); video("Live/IMG_3001.MOV", 2, 1)
save(scene(51), "Live/IMG_3002.JPG"); exif("Live/IMG_3002.JPG", "2021:01:10 18:30:00", "+00:00", LIS); video("Live/IMG_3002.MOV", 20, 2)
case("a short clip is a Live Photo's companion; a long video is not",
     companion={"Live/IMG_3001.JPG": "Live/IMG_3001.MOV"}, notcompanion=["Live/IMG_3002.MOV"],
     output={"Live/IMG_3001.JPG": "2021/01/20210110_180000.jpg", "Live/IMG_3001.MOV": "2021/01/20210110_180000.mov"})

# 14. a video copied twice is one recording
video("Clips/clip_x.mov", 5, 3); shutil.copy(OUT / "Clips/clip_x.mov", OUT / "Backup/clip_x.mov")
case("a copied video is one recording", same=["Clips/clip_x.mov", "Backup/clip_x.mov"])

# 15. the extension lies: a HEIC named .jpg is saved as .heic
save(scene(60), "tmp.jpg"); subprocess.run(["sips", "-s", "format", "heic", str(OUT / "tmp.jpg"), "--out", str(OUT / "tmp.heic")], check=True, capture_output=True)
exif("tmp.heic", "2021:01:25 09:00:00", "+09:00", TYO)     # exiftool will not write a mislabelled file
(OUT / "tmp.jpg").unlink(); (OUT / "tmp.heic").rename(OUT / "Phone/IMG_4001.jpg")
case("the file's real type decides the extension", output={"Phone/IMG_4001.jpg": "2021/01/20210125_090000.heic"})

# 16. what a saved copy must carry: the sidecar photo gains date, offset and GPS in its file
case("the saved copy carries what was worked out",
     written={T + "IMG_0088 (1).jpeg": {"DateTimeOriginal": "2021:01:05 10:00:00", "OffsetTimeOriginal": "-05:00",
                                        "GPSLatitude": NYC[0]}})

(OUT / "truth.json").write_text(json.dumps(truth, indent=1, ensure_ascii=False))
media = [p for p in OUT.rglob("*") if p.is_file() and p.suffix.lower() in (".jpg", ".jpeg", ".heic", ".mov")]
print(f"{len(media)} media files, {len(truth['cases'])} cases -> {OUT}")
