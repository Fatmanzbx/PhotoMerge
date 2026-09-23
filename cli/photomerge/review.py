"""Contact sheets for the decisions worth a human glance.

Thirty seconds of looking beats an hour of CSV rows, and it is the only way to
build real confidence in a threshold (README §4). Two things reach this queue:

* **Refusals** — pairs tier D would not confirm. These are unresolved by design.
* **The weakest confirmations** — merges that *did* happen, ranked by how thin the
  evidence was. Nobody audits 8,000 merges; the point is to look at the ten most
  likely to be wrong, because if those are right the rest almost certainly are.

The second list matters more. A refusal costs disk; a wrong confirmation costs a
photograph, and it is the one nothing downstream will question.
"""

from __future__ import annotations

import html
import json
import re
import sqlite3
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw

from photomerge.imagehash import open_oriented

TILE = 220
COLUMNS = 5
_SSIM = re.compile(r"SSIM ([0-9.]+)")


def _risk(reason: str) -> float:
    """How much this merge wants a human, lowest first.

    Ranking on SSIM alone hid the two rules most worth checking: a merge
    confirmed by per-tile difference or by keypoint geometry carries no SSIM in
    its reason, scored 1.0, and so never surfaced — precisely inverting the
    intent, because those are the newest and least proven paths.
    """
    if "flat images" in reason:
        return 0.0      # newest rule, and the classic false-merge hazard
    if "same geometry" in reason:
        return 0.1      # confirmed without a structural check
    found = _SSIM.search(reason)
    return float(found.group(1)) if found else 1.0


@dataclass
class Item:
    kind: str          # merge | refusal
    title: str
    note: str
    sheet: str
    score: float


def write_review(db: sqlite3.Connection, out_dir: Path, *, sample: int = 12) -> list[Item]:
    out_dir.mkdir(parents=True, exist_ok=True)
    # Cluster ids are reassigned on every run, so yesterday's sheets do not just
    # go stale, they point at different photographs. Leaving them beside the new
    # ones is worse than not writing sheets at all.
    for old in list(out_dir.glob("*.png")) + list(out_dir.glob("index.html")):
        old.unlink()
    items: list[Item] = []
    items += _weakest_merges(db, out_dir, sample)
    items += _refusals(db, out_dir, sample)
    _index(out_dir, items)
    return items


def _weakest_merges(db, out_dir: Path, sample: int) -> list[Item]:
    """Perceptual merges with the least convincing evidence, weakest first."""
    rows = db.execute("""
        SELECT m.cluster_id, d.reason, COUNT(*) OVER (PARTITION BY m.cluster_id) AS n
        FROM decision d
        JOIN member m ON m.file_id = d.file_id
        JOIN cluster c ON c.id = m.cluster_id
        WHERE d.outcome = 'duplicate' AND c.method = 'perceptual'
    """).fetchall()
    weakest: dict[int, tuple[float, str]] = {}
    for r in rows:
        score = _risk(r["reason"] or "")
        if r["cluster_id"] not in weakest or score < weakest[r["cluster_id"]][0]:
            weakest[r["cluster_id"]] = (score, r["reason"])

    items = []
    for cluster_id, (score, reason) in sorted(weakest.items(), key=lambda kv: kv[1][0])[:sample]:
        members = db.execute("""
            SELECT f.path, f.source, f.width, f.height, f.mime, m.role
            FROM member m JOIN file f ON f.id = m.file_id
            WHERE m.cluster_id = ? ORDER BY m.role != 'canonical'""",
            (cluster_id,)).fetchall()
        name = f"merge_{score:.3f}_cluster{cluster_id}.png"
        if _sheet([(r["path"], f"{r['role'][:4]} {r['source'][:10]} "
                               f"{r['width']}x{r['height']}") for r in members],
                  out_dir / name):
            items.append(Item("merge", f"Merged {len(members)} files — cluster {cluster_id}",
                              reason, name, score))
    return items


def _refusals(db, out_dir: Path, sample: int) -> list[Item]:
    rows = db.execute(
        "SELECT file_a, file_b, verdict, reason, checks_json FROM review "
        "ORDER BY verdict, id").fetchall()
    by_verdict: dict[str, int] = {}
    items = []
    for r in rows:
        # A few of each kind is enough to judge whether the rule is behaving.
        seen = by_verdict.get(r["verdict"], 0)
        if seen >= max(3, sample // 3):
            continue
        by_verdict[r["verdict"]] = seen + 1
        files = db.execute(
            "SELECT path, source, width, height FROM file WHERE id IN (?,?)",
            (r["file_a"], r["file_b"])).fetchall()
        name = f"refused_{r['verdict']}_{r['file_a']}_{r['file_b']}.png"
        if _sheet([(f["path"], f"{f['source'][:10]} {f['width']}x{f['height']}")
                   for f in files], out_dir / name):
            items.append(Item("refusal", f"Refused — {r['verdict']}", r["reason"], name, 0.0))
    return items


def _sheet(entries: list[tuple[str, str]], path: Path) -> bool:
    entries = entries[:10]
    rows = (len(entries) + COLUMNS - 1) // COLUMNS or 1
    sheet = Image.new("RGB", (COLUMNS * TILE, rows * (TILE + 18)), (26, 26, 28))
    draw = ImageDraw.Draw(sheet)
    drawn = 0
    for i, (source_path, label) in enumerate(entries):
        try:
            im = open_oriented(source_path).convert("RGB")
        except Exception:
            continue
        im.thumbnail((TILE, TILE))
        x, y = (i % COLUMNS) * TILE, (i // COLUMNS) * (TILE + 18)
        sheet.paste(im, (x + (TILE - im.width) // 2, y + (TILE - im.height) // 2))
        draw.text((x + 4, y + TILE + 3), label, fill=(210, 210, 215))
        drawn += 1
    if not drawn:
        return False
    sheet.save(path)
    return True


def _index(out_dir: Path, items: list[Item]) -> None:
    parts = ["<!doctype html><meta charset=utf-8><title>photomerge review</title>",
             "<style>body{background:#151518;color:#e8e8ea;font:14px/1.5 ui-sans-serif,"
             "system-ui,sans-serif;margin:0;padding:32px}h1{font-size:20px}"
             "h2{font-size:15px;margin:32px 0 4px}p{margin:0 0 8px;color:#a8a8b0}"
             "img{max-width:100%;border-radius:6px;background:#000}"
             "section{margin-bottom:28px}</style>",
             "<h1>photomerge review</h1>"]
    merges = [i for i in items if i.kind == "merge"]
    refusals = [i for i in items if i.kind == "refusal"]
    if merges:
        parts.append("<h1 style='font-size:16px;margin-top:24px'>Weakest merges — "
                     "these already happened</h1><p>Ranked by how thin the evidence "
                     "was. If these are right, the stronger ones are too.</p>")
        parts += [_block(i) for i in merges]
    if refusals:
        parts.append("<h1 style='font-size:16px;margin-top:32px'>Refusals — nothing "
                     "was merged</h1><p>Pairs the tool would not decide.</p>")
        parts += [_block(i) for i in refusals]
    (out_dir / "index.html").write_text("\n".join(parts), encoding="utf-8")


def _block(item: Item) -> str:
    return (f"<section><h2>{html.escape(item.title)}</h2>"
            f"<p>{html.escape(item.note or '')}</p>"
            f"<img src='{html.escape(item.sheet)}'></section>")
