#!/usr/bin/env python3
"""Build a duplicate-detection corpus with known ground truth.

Each source photograph becomes a family of derived files whose correct grouping we
know exactly, so the cascade can be asserted rather than eyeballed.
"""
import json, random, shutil, subprocess, sys
from pathlib import Path
from PIL import Image, ImageEnhance

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
N   = int(sys.argv[3]) if len(sys.argv) > 3 else 60

random.seed(7)
if OUT.exists(): shutil.rmtree(OUT)
OUT.mkdir(parents=True)

photos = [p for p in SRC.rglob('*') if p.suffix.lower() in ('.jpg', '.jpeg')][:4000]
random.shuffle(photos)
photos = photos[:N]

truth = []          # list of {"group": [files...], "kind": ...}
singles = []

for i, src in enumerate(photos):
    try:
        im = Image.open(src).convert('RGB')
    except Exception:
        continue
    stem = f"p{i:03d}"
    fam = []

    # 0. the original
    a = OUT / f"{stem}_orig.jpg"; im.save(a, quality=95); fam.append(a.name)

    if i % 6 == 0:
        # TIER A — byte-identical copy
        b = OUT / f"{stem}_copyA.jpg"; shutil.copy2(a, b); fam.append(b.name)
        kind = "exact"
    elif i % 6 == 1:
        # TIER B — same pixels, metadata rewritten
        b = OUT / f"{stem}_metaB.jpg"; shutil.copy2(a, b)
        subprocess.run(["exiftool", "-overwrite_original", "-q", "-m",
                        "-Artist=PhotoMerge", "-Copyright=test", str(b)], check=False)
        fam.append(b.name); kind = "pixel"
    elif i % 6 == 2:
        # TIER C — heavy recompression (the case a tight radius loses)
        b = OUT / f"{stem}_q40.jpg"; im.save(b, quality=40); fam.append(b.name)
        kind = "recompress"
    elif i % 6 == 3:
        # TIER C — resized to 50%
        b = OUT / f"{stem}_half.jpg"
        im.resize((max(1, im.width // 2), max(1, im.height // 2))).save(b, quality=90)
        fam.append(b.name); kind = "resize"
    elif i % 6 == 4:
        # MUST NOT MERGE — a tone grade is a different picture to look at
        b = OUT / f"{stem}_graded.jpg"
        ImageEnhance.Color(ImageEnhance.Brightness(im).enhance(1.18)).enhance(1.6).save(b, quality=92)
        singles.append(b.name); kind = "graded"
    else:
        # MUST NOT MERGE — a different photograph stamped with the same second
        other = photos[(i + 7) % len(photos)]
        try:
            o = Image.open(other).convert('RGB')
        except Exception:
            o = im.rotate(7)
        b = OUT / f"{stem}_burst.jpg"; o.resize(im.size).save(b, quality=92)
        singles.append(b.name); kind = "burst"

    # every family shares one capture instant, as real copies and real bursts both do
    ts = f"2021:03:{(i % 27) + 1:02d} 1{i % 10}:2{i % 6}:0{i % 10}"
    for name in fam + ([b.name] if kind in ("graded", "burst") else []):
        subprocess.run(["exiftool", "-overwrite_original", "-q", "-m",
                        f"-EXIF:DateTimeOriginal={ts}", f"-EXIF:CreateDate={ts}",
                        str(OUT / name)], check=False)

    if len(fam) > 1:
        truth.append({"group": fam, "kind": kind})
    else:
        singles.extend(fam)
    if kind in ("graded", "burst"):
        # the original is its own photograph; the derived file is another
        pass

meta = {"groups": truth, "singles": singles,
        "expected_groups": len(truth),
        "expected_files": len(list(OUT.glob('*.jpg')))}
(OUT / "_truth.json").write_text(json.dumps(meta, indent=1))
print(f"  corpus: {meta['expected_files']} files")
print(f"  families that MUST merge: {len(truth)}")
for k in ("exact", "pixel", "recompress", "resize"):
    print(f"      {k:<11} {sum(1 for t in truth if t['kind']==k)}")
print(f"  files that MUST stay separate: {len(singles)}")
