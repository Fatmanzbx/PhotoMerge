#!/usr/bin/env python3
"""Score PhotoMerge against a library from Tests/known_library.py.

    Tests/check_known.py <library> <catalog> <out>

Reads the catalog the `known` test subcommand produced, its <catalog>.audit.json,
and the clean library written to <out> (read back with exiftool). Prints PASS or
FAIL per case, with the reason; exits non-zero on any failure.
"""
import json, math, sqlite3, subprocess, sys
from pathlib import Path

LIB, CAT, OUT = Path(sys.argv[1]).resolve(), sys.argv[2], Path(sys.argv[3]).resolve()
truth = json.loads((LIB / "truth.json").read_text())
db = sqlite3.connect(CAT); db.row_factory = sqlite3.Row
audit = json.loads(Path(CAT + ".audit.json").read_text())

files = {r["rel_path"]: r for r in db.execute("SELECT * FROM file")}
def fid(rel):
    if rel not in files: raise KeyError(f"not catalogued: {rel}")
    return files[rel]["id"]
def membership(rel):
    return db.execute("SELECT cluster_id, role FROM member WHERE file_id=?", (fid(rel),)).fetchone()
def resolution(rel):
    m = membership(rel)
    return db.execute("SELECT * FROM resolution WHERE cluster_id=?", (m["cluster_id"],)).fetchone()
def norm(t): return None if t is None else t.replace("-", ":", 2).replace("T", " ")[:19]
def km(a, b):
    p = math.pi / 180
    h = math.sin((b[0]-a[0])*p/2)**2 + math.cos(a[0]*p)*math.cos(b[0]*p)*math.sin((b[1]-a[1])*p/2)**2
    return 12742 * math.asin(math.sqrt(h))
def target(rel):
    r = db.execute("SELECT target, state FROM output WHERE file_id=?", (fid(rel),)).fetchone()
    if not r: return None, None
    t = Path(r["target"]); return (str(t.relative_to(OUT)) if t.is_absolute() else r["target"]), r["state"]

def check(c):
    bad = []
    for rel in c.get("same", [])[1:]:
        if membership(rel)["cluster_id"] != membership(c["same"][0])["cluster_id"]:
            bad.append(f"{rel} not merged with {c['same'][0]}")
    for grp in c.get("separate", []):
        ids = {membership(r)["cluster_id"] for r in grp}
        if len(ids) != len(grp): bad.append(f"merged: {grp}")
    if "canonical" in c and membership(c["canonical"])["role"] != "canonical":
        bad.append(f"{c['canonical']} is {membership(c['canonical'])['role']}, not the copy kept")
    if "pair" in c:
        a, b = sorted(fid(r) for r in c["pair"]["files"])
        row = db.execute("SELECT outcome FROM pair WHERE a=? AND b=?", (a, b)).fetchone()
        if not row or row["outcome"] != c["pair"]["outcome"]:
            bad.append(f"pair outcome {row['outcome'] if row else 'none'}, want {c['pair']['outcome']}")
    for rel, (local, off, src) in c.get("time", {}).items():
        r = resolution(rel)
        if norm(r["local_time"]) != local: bad.append(f"{rel}: time {r['local_time']}, want {local}")
        if r["utc_offset"] != off: bad.append(f"{rel}: offset {r['utc_offset']}, want {off}")
        if src and src not in (r["time_source"] or ""): bad.append(f"{rel}: time source '{r['time_source']}', want '{src}'")
    for rel, src in c.get("timesource", {}).items():
        if src not in (resolution(rel)["time_source"] or ""): bad.append(f"{rel}: time source '{resolution(rel)['time_source']}'")
    for rel, (off, src) in c.get("zone", {}).items():
        r = resolution(rel)
        if r["utc_offset"] != off: bad.append(f"{rel}: offset {r['utc_offset']}, want {off}")
        if src not in (r["zone_source"] or ""): bad.append(f"{rel}: zone source '{r['zone_source']}', want '{src}'")
    for rel, src in c.get("place", {}).items():
        r = resolution(rel)
        if src == "none":
            if r["lat"] is not None: bad.append(f"{rel}: placed at {r['lat']},{r['lon']} by '{r['place_source']}', want no place")
        elif src not in (r["place_source"] or ""): bad.append(f"{rel}: place source '{r['place_source']}', want '{src}'")
    for rel, pt in c.get("near", {}).items():
        r = resolution(rel)
        if r["lat"] is None or km((r["lat"], r["lon"]), pt) > 2: bad.append(f"{rel}: placed at {r['lat']},{r['lon']}")
    for rel, rule in c.get("sidecar_rule", {}).items():
        got = files[rel]["sidecar_rule"]
        if got is None or rule not in got: bad.append(f"{rel}: sidecar rule {got}, want {rule}")
    for rel, main in c.get("companion", {}).items():
        mc = membership(rel)["cluster_id"]; m = membership(main)
        if m["cluster_id"] != mc or m["role"] != "companion": bad.append(f"{main} is {m['role']} of {m['cluster_id']}, want companion of {mc}")
    for rel in c.get("notcompanion", []):
        if membership(rel)["role"] == "companion": bad.append(f"{rel} made a companion")
    flagged = {a["cluster"]: a for a in audit}
    for rel, want in c.get("audit", {}).items():
        a = flagged.get(membership(rel)["cluster_id"])
        if not a: bad.append(f"{rel}: not flagged")
        elif a["expected"] != want: bad.append(f"{rel}: flagged, expecting {a['expected']}, want {want}")
    for rel in c.get("noaudit", []):
        if membership(rel)["cluster_id"] in flagged: bad.append(f"{rel}: flagged wrongly")
    for rel, want in c.get("output", {}).items():
        got, state = target(rel)
        if got != want: bad.append(f"{rel}: written to {got} ({state}), want {want}")
        elif not (OUT / got).exists(): bad.append(f"{got} missing on disk")
    for rel, tags in c.get("written", {}).items():
        got, _ = target(rel)
        if not got: bad.append(f"{rel}: not written"); continue
        j = json.loads(subprocess.run(["exiftool", "-j", "-n", *[f"-{k}" for k in tags], str(OUT / got)],
                                      capture_output=True, text=True).stdout)[0]
        for k, v in tags.items():
            g = j.get(k)
            ok = abs(float(g) - v) < 1e-4 if isinstance(v, float) and g is not None else str(g) == str(v)
            if not ok: bad.append(f"{got}: {k}={g}, want {v}")
    return bad

fails = 0
for c in truth["cases"]:
    try: bad = check(c)
    except Exception as e: bad = [f"{type(e).__name__}: {e}"]
    print(("PASS  " if not bad else "FAIL  ") + c["name"])
    for b in bad: print("        " + b)
    fails += bool(bad)

# Whole-library invariants: every output verified, nothing half-written, nothing lost.
rows = db.execute("SELECT state, count(*) n FROM output GROUP BY state").fetchall()
partial = [p for p in OUT.rglob("*.photomerge-partial*")]
canon = db.execute("SELECT count(*) FROM member WHERE role IN ('canonical','companion')").fetchone()[0]
written = sum(1 for p in OUT.rglob("*") if p.is_file() and not p.name.startswith("."))
inv = []
if any(r["state"] != "verified" for r in rows): inv.append(f"output states {[tuple(r) for r in rows]}")
if partial: inv.append(f"partial files left: {partial}")
if written != canon: inv.append(f"{written} files written for {canon} photos and companions")
print(("PASS  " if not inv else "FAIL  ") + f"every photo written once and verified ({written} files)")
for b in inv: print("        " + b)
fails += bool(inv)
print(f"\n{len(truth['cases']) + 1 - fails}/{len(truth['cases']) + 1} passed")
sys.exit(1 if fails else 0)
