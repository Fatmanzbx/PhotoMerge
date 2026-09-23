"""`photomerge explain` — why did this file end up where it did?

This exists because of what §5b says about move mode: once `.trash/` is
reclaimed the analysis is non-repeatable, and the pixels that justified a
decision are gone. The catalog is not. Every question this answers — which
cluster, who won and why, which claims competed, what was rejected — is
answered from the catalog alone, so it keeps working after the evidence itself
has been deleted.

It takes a path or any fragment of one, from either side of the merge: a source
file ("what happened to this?") or an output name ("where did this come from?").
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path


def explain(db: sqlite3.Connection, needle: str) -> list[str]:
    matches = _find(db, needle)
    if not matches:
        return [f"nothing in the catalog matches {needle!r}.",
                "Try a filename fragment, or an output name like 20241127_114817."]
    lines: list[str] = []
    for n, row in enumerate(matches):
        if n:
            lines.append("")
        lines.extend(_one(db, row))
    if len(matches) == 1:
        return lines
    return [f"{len(matches)} files match {needle!r}:", ""] + lines


def _find(db, needle: str, limit: int = 6):
    like = f"%{needle}%"
    rows = db.execute("""
        SELECT f.* FROM file f
        LEFT JOIN decision d ON d.file_id = f.id
        WHERE f.path LIKE ? OR d.target_path LIKE ?
        ORDER BY f.path LIMIT ?""", (like, like, limit)).fetchall()
    return rows


def _one(db, f) -> list[str]:
    out = [f"{Path(f['path']).name}",
           f"  source      {f['source']}  ({f['rel_path']})",
           f"  type        {f['mime']}  {f['width']}x{f['height']}  "
           f"{f['size']:,} bytes"]
    if f["make"] or f["model"]:
        out.append(f"  camera      {f['make'] or '?'} {f['model'] or ''}".rstrip())
    if f["sharpness"] is not None:
        out.append(f"  sharpness   {f['sharpness']:.0f}")
    if f["content_id"]:
        out.append(f"  content id  {f['content_id']}  (Live Photo pairing)")
    if f["status"] != "extracted":
        out.append(f"  status      {f['status']}  {f['error'] or ''}")

    decision = db.execute(
        "SELECT * FROM decision WHERE file_id = ?", (f["id"],)).fetchone()
    member = db.execute(
        "SELECT * FROM member WHERE file_id = ?", (f["id"],)).fetchone()

    if member:
        cluster = db.execute("SELECT * FROM cluster WHERE id = ?",
                             (member["cluster_id"],)).fetchone()
        siblings = db.execute("""
            SELECT f.path, f.source, f.mime, f.width, f.height, f.size, m.role
            FROM member m JOIN file f ON f.id = m.file_id
            WHERE m.cluster_id = ? ORDER BY m.role != 'canonical', f.path""",
            (member["cluster_id"],)).fetchall()
        out += ["", f"  ASSET       cluster {cluster['id']} — matched by "
                    f"{_method(cluster['method'])}, {len(siblings)} file(s)"]
        for s in siblings:
            mark = "->" if s["path"] == f["path"] else "  "
            out.append(f"   {mark} {s['role']:13s} {s['source']:15s} "
                       f"{s['width']}x{s['height']:<5} {s['size']:>10,}  "
                       f"{Path(s['path']).name[:40]}")

    if decision:
        out += ["", f"  DECISION    {decision['outcome']}"]
        out.append(f"              {decision['reason']}")
        if decision["target_path"]:
            out.append(f"  writes to   {decision['target_path']}")
        if decision["verified_at"]:
            out.append(f"  verified    {decision['verified_at']}  "
                       f"(pixels re-read and confirmed identical)")
        elif decision["outcome"] in ("duplicate", "burst_sibling"):
            keeper = db.execute(
                "SELECT d.target_path, d.verified_at, f.path FROM decision d "
                "JOIN file f ON f.id = d.file_id WHERE d.id = ?",
                (decision["superseded_by"],)).fetchone() if decision["superseded_by"] else None
            if keeper and keeper["verified_at"]:
                out.append(f"  replaced by {keeper['target_path']}  (verified, so this "
                           f"file may be reclaimed)")
            else:
                out.append("  replaced by nothing verified yet — this file will NOT be "
                           "staged or unlinked")

    if member:
        out += _resolved(db, member["cluster_id"])
    out += _claims(db, f["id"])
    out += _reviews(db, f["id"])
    return out


def _method(method: str) -> str:
    return {
        "exact": "identical bytes (sha256)",
        "pixel": "identical pixels after decoding",
        "perceptual": "appearance, then confirmed by the verification cascade",
        "burst": "a burst — same camera, same instant, different frames",
    }.get(method, method)


def _resolved(db, cluster_id: int) -> list[str]:
    rows = db.execute(
        "SELECT field, value, source, confidence, competing_json FROM resolution "
        "WHERE cluster_id = ? ORDER BY field", (cluster_id,)).fetchall()
    if not rows:
        return ["", "  METADATA    not resolved yet — run `photomerge resolve`"]
    out = ["", "  METADATA    what this asset was given, and what lost"]
    for r in rows:
        if r["field"] in ("capture_stem",):
            continue
        out.append(f"    {r['field']:14s} {str(r['value'])[:46]:48s} from {r['source']}")
        if r["competing_json"]:
            payload = json.loads(r["competing_json"])
            if payload.get("note"):
                out.append(f"      note: {payload['note']}")
            for other in (payload.get("competing") or [])[:4]:
                out.append(f"      rejected: {other.get('value')}  "
                           f"({other.get('source')})")
    return out


def _claims(db, file_id: int) -> list[str]:
    rows = db.execute(
        "SELECT field, value, source, confidence FROM meta WHERE file_id = ? "
        "ORDER BY field, confidence DESC", (file_id,)).fetchall()
    if not rows:
        return []
    out = ["", "  ITS OWN CLAIMS   everything this one file said about itself"]
    seen = set()
    for r in rows:
        key = (r["field"], r["value"], r["source"])
        if key in seen:
            continue
        seen.add(key)
        out.append(f"    {r['source']:12s} {r['field']:16s} "
                   f"{str(r['value'])[:42]:44s} conf {r['confidence']}")
    sidecar = db.execute(
        "SELECT kind, path, rule FROM sidecar WHERE file_id = ?", (file_id,)).fetchall()
    for s in sidecar:
        out.append(f"    sidecar      {s['kind']:16s} matched by rule '{s['rule']}'")
        out.append(f"                 {Path(s['path']).name[:60]}")
    return out


def _reviews(db, file_id: int) -> list[str]:
    rows = db.execute("""
        SELECT r.verdict, r.reason, f.path AS other
        FROM review r JOIN file f
          ON f.id = CASE WHEN r.file_a = ? THEN r.file_b ELSE r.file_a END
        WHERE r.file_a = ? OR r.file_b = ?""", (file_id, file_id, file_id)).fetchall()
    if not rows:
        return []
    out = ["", "  UNRESOLVED  pairs the tool would not decide"]
    for r in rows:
        out.append(f"    [{r['verdict']}] vs {Path(r['other']).name[:40]}")
        out.append(f"      {r['reason']}")
    return out
