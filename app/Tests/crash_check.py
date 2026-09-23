#!/usr/bin/env python3
"""Invariants for Tests/crash_test.sh.

    crash_check.py <lib> <catalog> snapshot            record every original's hash
    crash_check.py <lib> <catalog> output <out>        the clean library is whole
    crash_check.py <lib> <catalog> undone <out>        nothing written is left
    crash_check.py <lib> <catalog> tidied <trash>      duplicates gone, all restorable
    crash_check.py <lib> <catalog> restored <trash>    the library is as it began
"""
import hashlib, json, sqlite3, sys
from pathlib import Path

lib, cat, mode = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
snap = Path(cat + ".originals.json")
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def originals(): return {str(p.relative_to(lib)): sha(p) for p in sorted(lib.rglob("*")) if p.is_file()}
db = sqlite3.connect(cat)
q = lambda s, *a: db.execute(s, a).fetchall()
bad = []

if mode == "snapshot":
    snap.write_text(json.dumps(originals())); print(len(originals()), "originals"); sys.exit(0)
before = json.loads(snap.read_text())

if mode in ("output", "undone"):
    out = Path(sys.argv[4])
    now = originals()
    if now != before: bad.append(f"originals changed: {[k for k in before if now.get(k) != before[k]][:5]}")
    files = {str(p.relative_to(out)) for p in out.rglob("*") if p.is_file() and p.name != ".DS_Store"} if out.exists() else set()
    rows = {t: s for t, s in q("SELECT target, written_sha FROM output WHERE state='verified'")}
    partial = [f for f in files if ".photomerge-partial" in f]
    if partial: bad.append(f"{len(partial)} half-written files left: {partial[:3]}")
    if mode == "output":
        want = q("SELECT count(*) FROM member WHERE role IN ('canonical','companion')")[0][0]
        other = q("SELECT state, count(*) FROM output WHERE state != 'verified' GROUP BY state")
        if other: bad.append(f"unfinished manifest rows: {other}")
        if len(rows) != want: bad.append(f"{len(rows)} verified for {want} photographs")
        orphans = sorted(files - set(rows) - set(partial))
        if orphans: bad.append(f"{len(orphans)} files on disk the manifest does not know (Undo would leave them): {orphans[:3]}")
        missing = [t for t in rows if t not in files]
        if missing: bad.append(f"{len(missing)} verified files missing: {missing[:3]}")
        wrong = [t for t, s in rows.items() if t in files and sha(out / t) != s]
        if wrong: bad.append(f"{len(wrong)} files differ from what was verified: {wrong[:3]}")
        dup = q("SELECT file_id, count(*) FROM output GROUP BY file_id HAVING count(*) > 1")
        if dup: bad.append(f"photographs written twice: {dup[:3]}")
        print(f"    {len(rows)} written, {len(files)} on disk")
    else:
        if files: bad.append(f"{len(files)} files left after undo: {sorted(files)[:3]}")
        if rows: bad.append(f"{len(rows)} manifest rows left after undo")

if mode in ("tidied", "restored"):
    trash = Path(sys.argv[4])
    now = originals()
    in_trash = sorted(p for p in trash.rglob("*") if p.is_file()) if trash.exists() else []
    changed = [k for k in now if k in before and now[k] != before[k]]
    if changed: bad.append(f"files changed: {changed[:3]}")
    extra = [k for k in now if k not in before]
    if extra: bad.append(f"unexpected files: {extra[:3]}")
    gone = [k for k in before if k not in now]
    recorded = {Path(t).name for (t,) in q("SELECT trash_path FROM trashed")}
    if mode == "tidied":
        dups = {r for (r,) in q("SELECT f.rel_path FROM member m JOIN file f ON f.id=m.file_id WHERE m.role='duplicate'")}
        kept = {r for (r,) in q("SELECT f.rel_path FROM member m JOIN file f ON f.id=m.file_id WHERE m.role='canonical'")}
        if set(gone) != dups: bad.append(f"removed {len(gone)}, duplicates {len(dups)}; not duplicates: {sorted(set(gone) - dups)[:3]}")
        if kept & set(gone): bad.append(f"kept copies removed: {sorted(kept & set(gone))[:3]}")
        lost = [p.name for p in in_trash if p.name not in recorded]
        if lost: bad.append(f"{len(lost)} files in the Trash that Restore does not know about: {lost[:3]}")
        trashed_shas = sorted(sha(p) for p in in_trash); want = sorted(before[k] for k in gone)
        if trashed_shas != want: bad.append("what is in the Trash is not exactly what left the library")
        print(f"    {len(gone)} duplicates in the Trash, {len(recorded)} recorded")
    else:
        if gone: bad.append(f"{len(gone)} originals not back: {gone[:3]}")
        if in_trash: bad.append(f"{len(in_trash)} still in the Trash")
        if q("SELECT count(*) FROM trashed")[0][0]: bad.append("restore records left")

for b in bad: print("    FAIL " + b)
print("    " + ("ok" if not bad else "FAILED") + f" ({mode})")
sys.exit(1 if bad else 0)
