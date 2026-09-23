#!/usr/bin/env python3
"""
photomerge.py — 合并 Mac / iPad / Google Takeout 的照片, 去重, 并尽力保住拍摄时间与 GPS。

核心思想: 一张照片的"最好画质版本"和"最全元数据版本"往往不是同一个文件。
所以先按内容聚类, 每组挑画质最好的做底片, 再把同组其它副本里的
时间 / GPS / 机型 补回去 (union), 最后用 exiftool 写进输出文件。

用法:
    python3 photomerge.py --src ~/PhotoMerge/mac --src ~/PhotoMerge/ipad \
                          --src ~/PhotoMerge/gphotos --out ~/PhotoMerge/RESULT

    --dry-run       只出报告, 不写任何文件 (建议先跑这个)
    --threshold N   dHash 汉明距离阈值, 默认 6; 连拍多就调到 3~4
    --no-write-meta 只复制, 不回填元数据

依赖: pip install pillow numpy pillow-heif   +   brew install exiftool
"""

import argparse, csv, hashlib, json, os, shutil, subprocess, sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from PIL import Image, ExifTags

try:
    import pillow_heif; pillow_heif.register_heif_opener(); HEIC_OK = True
except ImportError:
    HEIC_OK = False

Image.MAX_IMAGE_PIXELS = None

IMG_EXT = {".jpg",".jpeg",".png",".heic",".heif",".tif",".tiff",".webp",
           ".bmp",".gif",".dng",".cr2",".nef",".arw"}
VID_EXT = {".mov",".mp4",".m4v",".avi",".3gp",".mkv"}
SKIP    = {".ds_store","thumbs.db","desktop.ini"}

TAG = {n: t for t, n in ExifTags.TAGS.items()}
GPSTAG = {n: t for t, n in ExifTags.GPSTAGS.items()}


# ------------------------------------------------------------------ hashes
def sha256(p, chunk=1 << 20):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(chunk), b""):
            h.update(b)
    return h.hexdigest()


def dhash(img, s=8):
    a = np.asarray(img.convert("L").resize((s + 1, s), Image.LANCZOS), dtype=np.int16)
    return np.packbits((a[:, 1:] > a[:, :-1]).flatten()).tobytes()


# ---------------------------------------------------------------- metadata
def _rat(v):
    try:    return float(v)
    except Exception: return None


def read_exif(path):
    """返回 dict: dt / lat / lon / alt / make / model, 缺的就是 None"""
    out = dict.fromkeys(("dt", "lat", "lon", "alt", "make", "model"))
    try:
        with Image.open(path) as im:
            ex = im.getexif()
            if not ex:
                return out, im.size
            size = im.size
            for name in ("DateTimeOriginal", "DateTimeDigitized", "DateTime"):
                v = ex.get(TAG.get(name)) or ex.get_ifd(0x8769).get(TAG.get(name))
                if v:
                    try:
                        out["dt"] = datetime.strptime(str(v)[:19], "%Y:%m:%d %H:%M:%S")
                        break
                    except ValueError:
                        pass
            out["make"]  = str(ex.get(TAG["Make"], "") or "").strip() or None
            out["model"] = str(ex.get(TAG["Model"], "") or "").strip() or None
            g = ex.get_ifd(0x8825)          # GPS IFD
            if g:
                def dms(v, ref, neg):
                    if not v: return None
                    d, m, s = (_rat(x) for x in v)
                    if None in (d, m, s): return None
                    val = d + m / 60 + s / 3600
                    return -val if str(ref).upper().startswith(neg) else val
                out["lat"] = dms(g.get(GPSTAG["GPSLatitude"]),  g.get(GPSTAG["GPSLatitudeRef"]),  "S")
                out["lon"] = dms(g.get(GPSTAG["GPSLongitude"]), g.get(GPSTAG["GPSLongitudeRef"]), "W")
                out["alt"] = _rat(g.get(GPSTAG["GPSAltitude"]))
            return out, size
    except Exception:
        return out, (0, 0)


def read_takeout_json(path):
    """Google Takeout 的边车 json —— 时间和地点的真正藏身处。"""
    p = Path(path)
    cands = [Path(str(p) + ".json"),
             Path(str(p) + ".supplemental-metadata.json"),
             p.with_suffix(".json")]
    # Takeout 会把长文件名截断到 51 字符, 所以再模糊找一次
    cands += sorted(p.parent.glob(p.stem[:40] + "*.json"))
    for c in cands:
        if not c.exists():
            continue
        try:
            d = json.loads(c.read_text())
        except Exception:
            continue
        out = dict.fromkeys(("dt", "lat", "lon", "alt", "make", "model"))
        ts = (d.get("photoTakenTime") or {}).get("timestamp")
        if ts:
            out["dt"] = datetime.fromtimestamp(int(ts), tz=timezone.utc)\
                                .astimezone().replace(tzinfo=None)
        for key in ("geoDataExif", "geoData"):
            g = d.get(key) or {}
            lat, lon = g.get("latitude"), g.get("longitude")
            if lat or lon:                       # 0,0 表示"没有地点"
                out["lat"], out["lon"], out["alt"] = lat, lon, g.get("altitude")
                break
        return out
    return None


def haversine(a, b):
    la1, lo1, la2, lo2 = map(np.radians, (a[0], a[1], b[0], b[1]))
    h = np.sin((la2-la1)/2)**2 + np.cos(la1)*np.cos(la2)*np.sin((lo2-lo1)/2)**2
    return 6371.0 * 2 * np.arcsin(np.sqrt(h))    # km


# -------------------------------------------------------------------- scan
def scan(sources):
    recs = []
    for prio, root in enumerate(sources):
        root = Path(root).expanduser().resolve()
        for p in sorted(root.rglob("*")):
            if not p.is_file() or p.name.lower() in SKIP or p.name.startswith("._"):
                continue
            e = p.suffix.lower()
            if e not in IMG_EXT and e not in VID_EXT:
                continue
            recs.append({"path": p, "src": root.name, "prio": prio, "ext": e,
                         "rel": p.relative_to(root),
                         "size": p.stat().st_size, "mtime": p.stat().st_mtime,
                         "kind": "img" if e in IMG_EXT else "vid",
                         "w": 0, "h": 0, "dhash": None,
                         "meta": dict.fromkeys(("dt","lat","lon","alt","make","model")),
                         "dt_src": "", "gps_src": "", "live_of": None, "role": ""})
    return tag_live_photos(recs)


def tag_live_photos(recs):
    """Live Photo 的 .MOV 与同目录同名图片是一对, 不能拆散、也不算'视频'。"""
    stem_img = {}
    for i, r in enumerate(recs):
        if r["kind"] == "img":
            stem_img[(r["path"].parent, r["path"].stem.lower())] = i
    for i, r in enumerate(recs):
        if r["kind"] == "vid" and r["ext"] in (".mov", ".mp4"):
            j = stem_img.get((r["path"].parent, r["path"].stem.lower()))
            if j is not None:
                r["live_of"] = j
                r["role"] = "live-companion"
                recs[j]["live"] = i
    for r in recs:
        if not r["role"]:
            r["role"] = "video" if r["kind"] == "vid" else "photo"
    return recs


def enrich(recs):
    n = len(recs)
    for i, r in enumerate(recs):
        if i % 250 == 0:
            print(f"  读取元数据 {i}/{n} ...", file=sys.stderr)
        r["sha"] = sha256(r["path"])
        exif, size = ({}, (0, 0))
        if r["kind"] == "img":
            exif, size = read_exif(r["path"])
            r["w"], r["h"] = size
            try:
                with Image.open(r["path"]) as im:
                    im.draft("L", (256, 256))
                    r["dhash"] = dhash(im)
            except Exception as e:
                print(f"  !! 读不了 {r['path']}: {e}", file=sys.stderr)
        js = read_takeout_json(r["path"])

        # 优先级: 文件内 EXIF > Takeout json > 文件修改时间
        m = r["meta"]
        for k in m:
            if exif.get(k) is not None:
                m[k] = exif[k]
                if k == "dt":  r["dt_src"]  = "exif"
                if k == "lat": r["gps_src"] = "exif"
            elif js and js.get(k) is not None:
                m[k] = js[k]
                if k == "dt":  r["dt_src"]  = "takeout-json"
                if k == "lat": r["gps_src"] = "takeout-json"
        if m["dt"] is None:
            m["dt"] = datetime.fromtimestamp(r["mtime"])
            r["dt_src"] = "mtime(不可靠)"
    return recs


# -------------------------------------------------------------- clustering
class DSU:
    def __init__(s, n): s.p = list(range(n))
    def find(s, x):
        while s.p[x] != x: s.p[x] = s.p[s.p[x]]; x = s.p[x]
        return x
    def union(s, a, b):
        ra, rb = s.find(a), s.find(b)
        if ra != rb: s.p[rb] = ra


def cluster(recs, thr):
    """只对 role=='photo' 的记录去重。视频一律全留, 由用户手动整理。"""
    d = DSU(len(recs))
    by_sha = defaultdict(list)
    for i, r in enumerate(recs):
        if r["role"] != "photo":
            continue
        by_sha[r["sha"]].append(i)
    for g in by_sha.values():
        for j in g[1:]:
            d.union(g[0], j)

    idx = [i for i, r in enumerate(recs) if r["dhash"] and r["role"] == "photo"]
    if idx:
        H = np.frombuffer(b"".join(recs[i]["dhash"] for i in idx),
                          dtype=np.uint8).reshape(len(idx), 8)
        bits = np.unpackbits(H, axis=1).astype(np.int8)
        D = (bits[:, None, :] != bits[None, :, :]).sum(2)
        ii, jj = np.where(np.triu(D <= thr, 1))
        for a, b in zip(ii, jj):
            ra, rb = recs[idx[a]], recs[idx[b]]
            ma, mb = ra["meta"], rb["meta"]
            # 两边都有可信时间且差超过 1 天 -> 不同照片
            if ra["dt_src"].startswith("exif") and rb["dt_src"].startswith("exif") \
               and abs((ma["dt"] - mb["dt"]).total_seconds()) > 86400:
                continue
            # 两边都有 GPS 且相距超过 5km -> 不同照片
            if None not in (ma["lat"], ma["lon"], mb["lat"], mb["lon"]) \
               and haversine((ma["lat"], ma["lon"]), (mb["lat"], mb["lon"])) > 5:
                continue
            d.union(idx[a], idx[b])

    g = defaultdict(list)
    for i, r in enumerate(recs):
        if r["role"] == "photo":
            g[d.find(i)].append(i)
    return list(g.values())


# ------------------------------------------------------- merge + emit
def score(r):
    """画质优先: 像素数 > 体积 > 来源优先级"""
    return (r["w"] * r["h"], r["size"], -r["prio"])


def merge_meta(recs, group):
    """底片选画质最好的; 元数据在整组里做并集, 每个字段挑最可信的来源。"""
    best = max(group, key=lambda i: score(recs[i]))
    merged, prov = dict(recs[best]["meta"]), {}
    rank = {"exif": 0, "takeout-json": 1, "mtime(不可靠)": 9, "": 9}

    # 时间: 全组里挑来源最可信的
    cand = sorted(group, key=lambda i: (rank.get(recs[i]["dt_src"], 9), recs[i]["prio"]))
    if cand and rank.get(recs[cand[0]]["dt_src"], 9) < rank.get(recs[best]["dt_src"], 9):
        merged["dt"] = recs[cand[0]]["meta"]["dt"]
        prov["dt"] = f'{recs[cand[0]]["src"]}:{recs[cand[0]]["dt_src"]}'

    # GPS / 机型: 底片没有就从同组别人那儿借
    for key in ("lat", "lon", "alt", "make", "model"):
        if merged.get(key) is None:
            for i in sorted(group, key=lambda i: recs[i]["prio"]):
                v = recs[i]["meta"].get(key)
                if v is not None:
                    merged[key] = v
                    if key == "lat":
                        prov["gps"] = f'{recs[i]["src"]}:{recs[i]["gps_src"]}'
                    break
    return best, merged, prov


def exiftool_args_video(dst, m):
    """MOV/MP4 的时间地点在 QuickTime/Keys 里, 写 EXIF 标签是没用的。"""
    t = f"{m['dt']:%Y:%m:%d %H:%M:%S}"
    a = ["-api", "QuickTimeUTC=1",
         f"-QuickTime:CreateDate={t}", f"-QuickTime:ModifyDate={t}",
         f"-Keys:CreationDate={t}", f"-FileModifyDate={t}"]
    if m.get("lat") is not None and m.get("lon") is not None:
        a.append(f"-Keys:GPSCoordinates={m['lat']} {m['lon']}")
        a.append(f"-UserData:GPSCoordinates={m['lat']} {m['lon']}")
    a += ["-overwrite_original", "-api", "LargeFileSupport=1", str(dst)]
    return a


def exiftool_args(dst, m):
    if Path(dst).suffix.lower() in VID_EXT:
        return exiftool_args_video(dst, m)
    a = [f"-DateTimeOriginal={m['dt']:%Y:%m:%d %H:%M:%S}",
         f"-CreateDate={m['dt']:%Y:%m:%d %H:%M:%S}",
         f"-FileModifyDate={m['dt']:%Y:%m:%d %H:%M:%S}",
         f"-FileCreateDate={m['dt']:%Y:%m:%d %H:%M:%S}"]
    if m.get("lat") is not None and m.get("lon") is not None:
        a += [f"-GPSLatitude={abs(m['lat'])}",  f"-GPSLatitudeRef={'N' if m['lat']>=0 else 'S'}",
              f"-GPSLongitude={abs(m['lon'])}", f"-GPSLongitudeRef={'E' if m['lon']>=0 else 'W'}"]
        if m.get("alt") is not None:
            a += [f"-GPSAltitude={abs(m['alt'])}", f"-GPSAltitudeRef={0 if m['alt']>=0 else 1}"]
    if m.get("make"):  a.append(f"-Make={m['make']}")
    if m.get("model"): a.append(f"-Model={m['model']}")
    a += ["-overwrite_original", "-api", "LargeFileSupport=1", str(dst)]
    return a


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", action="append", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--threshold", type=int, default=6)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-write-meta", action="store_true")
    a = ap.parse_args()

    if not HEIC_OK:
        print("提示: 没装 pillow-heif, HEIC 只能按字节去重 (pip install pillow-heif)", file=sys.stderr)
    have_et = shutil.which("exiftool") is not None
    if not have_et and not a.no_write_meta:
        print("提示: 没装 exiftool, 无法回填元数据 (brew install exiftool)", file=sys.stderr)

    print("扫描中...", file=sys.stderr)
    recs = scan(a.src)
    print(f"找到 {len(recs)} 个文件", file=sys.stderr)
    enrich(recs)
    groups = cluster(recs, a.threshold)

    out = Path(a.out).expanduser().resolve()
    report, jobs, used = [], [], set()

    def row(**kw):
        base = dict(role="", kept="", out="", path="", source="", dims="", size="",
                    own_datetime="", datetime_from="", own_gps="", gps_from="",
                    final_datetime="", final_gps="", borrowed="", cluster_size="",
                    dup_note="")
        base.update(kw); report.append(base)

    # ---------- 照片: 去重 + 元数据并集 ----------
    for g in groups:
        best, m, prov = merge_meta(recs, g)
        sub = out / f'{m["dt"]:%Y/%m}'
        name, k = recs[best]["path"].name, 1
        while (sub / name) in used:
            name = f'{recs[best]["path"].stem}_{k}{recs[best]["path"].suffix}'; k += 1
        dst = sub / name
        used.add(dst)
        jobs.append((recs[best]["path"], dst, m))

        # Live Photo 伴生 MOV: 跟着底片走, 同名同目录, 保住配对
        live = recs[best].get("live")
        if live is None:                       # 底片那份没有, 就从同组别人那儿拿
            for i in sorted(g, key=lambda i: recs[i]["prio"]):
                if recs[i].get("live") is not None:
                    live = recs[i]["live"]; break
        if live is not None:
            lv = dst.with_suffix(recs[live]["path"].suffix)
            jobs.append((recs[live]["path"], lv, m))
            row(role="live-companion", kept=True, out=str(lv),
                path=str(recs[live]["path"]), source=recs[live]["src"],
                size=recs[live]["size"], final_datetime=m["dt"].isoformat(),
                final_gps=f'{m["lat"]},{m["lon"]}' if m["lat"] is not None else "",
                dup_note="随所属照片一起保留")

        for i in g:
            row(role="photo", kept=(i == best), out=str(dst) if i == best else "",
                path=str(recs[i]["path"]), source=recs[i]["src"],
                dims=f'{recs[i]["w"]}x{recs[i]["h"]}', size=recs[i]["size"],
                own_datetime=recs[i]["meta"]["dt"].isoformat() if recs[i]["meta"]["dt"] else "",
                datetime_from=recs[i]["dt_src"],
                own_gps=f'{recs[i]["meta"]["lat"]},{recs[i]["meta"]["lon"]}'
                        if recs[i]["meta"]["lat"] is not None else "",
                gps_from=recs[i]["gps_src"],
                final_datetime=m["dt"].isoformat() if i == best else "",
                final_gps=(f'{m["lat"]},{m["lon"]}'
                           if i == best and m["lat"] is not None else ""),
                borrowed=";".join(f"{k}<{v}" for k, v in prov.items()) if i == best else "",
                cluster_size=len(g))

    # ---------- 视频: 一张不删, 原样搬到 _VIDEOS/ 供手动整理 ----------
    vids = [i for i, r in enumerate(recs) if r["role"] == "video"]
    same_bytes = defaultdict(list)
    same_name  = defaultdict(list)
    for i in vids:
        same_bytes[recs[i]["sha"]].append(i)
        same_name[recs[i]["path"].name.lower()].append(i)
    for i in vids:
        r = recs[i]
        dst = out / "_VIDEOS" / r["src"] / r["rel"]      # 保留原来的目录结构
        jobs.append((r["path"], dst, r["meta"]))
        notes = []
        if len(same_bytes[r["sha"]]) > 1:
            notes.append(f'字节完全相同的还有 {len(same_bytes[r["sha"]])-1} 份')
        elif len(same_name[r["path"].name.lower()]) > 1:
            notes.append(f'同名不同内容的还有 {len(same_name[r["path"].name.lower()])-1} 份(可能是不同压缩版)')
        row(role="video", kept=True, out=str(dst), path=str(r["path"]),
            source=r["src"], size=r["size"],
            own_datetime=r["meta"]["dt"].isoformat() if r["meta"]["dt"] else "",
            datetime_from=r["dt_src"],
            own_gps=f'{r["meta"]["lat"]},{r["meta"]["lon"]}'
                    if r["meta"]["lat"] is not None else "",
            gps_from=r["gps_src"],
            final_datetime=r["meta"]["dt"].isoformat() if r["meta"]["dt"] else "",
            final_gps=f'{r["meta"]["lat"]},{r["meta"]["lon"]}'
                      if r["meta"]["lat"] is not None else "",
            dup_note="; ".join(notes))

    if not a.dry_run:
        print("复制中...", file=sys.stderr)
        for src, dst, m in jobs:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)          # copy2 保留原始 mtime
        if have_et and not a.no_write_meta:
            print("回填时间/GPS...", file=sys.stderr)
            argfile = out / "_exiftool_args.txt"
            with open(argfile, "w") as f:
                for _, dst, m in jobs:
                    f.write("\n".join(exiftool_args(dst, m)) + "\n-execute\n")
            subprocess.run(["exiftool", "-@", str(argfile), "-common_args", "-q"], check=False)
            argfile.unlink(missing_ok=True)

    rep_dir = out if not a.dry_run else out.parent
    rep_dir.mkdir(parents=True, exist_ok=True)
    csv_path = rep_dir / "photomerge_report.csv"
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(report[0].keys()))
        w.writeheader(); w.writerows(report)

    n_photo = sum(1 for r in report if r["role"] == "photo" and r["kept"])
    n_live  = sum(1 for r in report if r["role"] == "live-companion")
    n_vid   = sum(1 for r in report if r["role"] == "video")
    dropped = sum(1 for r in report if r["role"] == "photo" and not r["kept"])
    no_gps  = sum(1 for r in report if r["kept"] and r["role"] == "photo" and not r["final_gps"])
    weak_dt = sum(1 for r in report if r["kept"] and r["role"] == "photo"
                  and str(r["datetime_from"]).startswith("mtime") and not r["borrowed"])
    borrowed = sum(1 for r in report if r["borrowed"])
    vid_dup = sum(1 for r in report if r["role"] == "video" and r["dup_note"])

    print(f"\n扫描 {len(recs)} 个文件:")
    print(f"  照片   {n_photo} 张 (去掉 {dropped} 份重复), 其中 {borrowed} 张借回了时间或 GPS")
    print(f"  Live   {n_live} 个伴生 MOV, 已与所属照片同名放一起")
    print(f"  视频   {n_vid} 个, 全部保留在 {out}/_VIDEOS/<来源>/ 下", end="")
    print(f", 其中 {vid_dup} 个疑似有重复 (报告 dup_note 列)" if vid_dup else "")
    print(f"  遗留   {no_gps} 张照片仍无 GPS, {weak_dt} 张时间只能靠文件修改时间(不可靠)")
    print(f"报告: {csv_path}   ← 先看这个再删原件")


if __name__ == "__main__":
    main()
