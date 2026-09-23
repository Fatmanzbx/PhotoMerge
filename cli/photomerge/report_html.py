"""`report.html` — did this actually work?

PLAN §5 names the number this page exists for: **metadata coverage before and
after**. Everything else here is context for it. A merge that halves the file
count but leaves the same proportion of photos undated has not done the job the
tool was built for; one that raises date and location coverage has, and by how
much is the only honest summary.

Self-contained: one file, inline styles, no network. Bars are plain divs so the
page renders the same in ten years as it does today.
"""

from __future__ import annotations

import html
import sqlite3
from datetime import datetime
from pathlib import Path

GB = 1073741824


def write_html(db: sqlite3.Connection, out_path: Path) -> Path:
    d = _gather(db)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(_render(d), encoding="utf-8")
    return out_path


def _one(db, sql, *args):
    row = db.execute(sql, args).fetchone()
    return (row[0] if row and row[0] is not None else 0)


def _gather(db) -> dict:
    files = _one(db, "SELECT COUNT(*) FROM file WHERE status='extracted'")
    assets = _one(db, "SELECT COUNT(*) FROM cluster")
    kept = _one(db, """SELECT SUM(f.size) FROM member m JOIN file f ON f.id=m.file_id
                       WHERE m.role IN ('canonical','companion','variant')""")
    dropped = _one(db, """SELECT SUM(f.size) FROM member m JOIN file f ON f.id=m.file_id
                          WHERE m.role IN ('duplicate','burst_sibling')""")

    # Coverage before: of the *input files*, how many knew this about themselves?
    # Coverage after: of the *output assets*, how many were given it?
    before_date = _one(db, """SELECT COUNT(DISTINCT file_id) FROM meta
        WHERE field IN ('datetime_utc','datetime_local') AND source != 'fs'""")
    before_gps = _one(db, "SELECT COUNT(DISTINCT file_id) FROM meta WHERE field='gps'")
    before_zone = _one(db, "SELECT COUNT(DISTINCT file_id) FROM meta WHERE field='utc_offset'")
    after_date = _one(db, "SELECT COUNT(*) FROM resolution WHERE field='datetime_utc'")
    after_gps = _one(db, "SELECT COUNT(*) FROM resolution WHERE field='gps'")
    after_zone = _one(db, "SELECT COUNT(*) FROM resolution WHERE field='utc_offset'")
    inferred_gps = _one(db, "SELECT COUNT(*) FROM resolution "
                            "WHERE field='gps' AND source='inferred'")
    derived_zone = _one(db, "SELECT COUNT(*) FROM resolution "
                            "WHERE field='utc_offset' AND source='derived'")

    return {
        "files": files, "assets": assets, "kept": kept, "dropped": dropped,
        "sources": db.execute("""SELECT source, COUNT(*) n, SUM(size)/1073741824.0 gb
            FROM file WHERE status='extracted' GROUP BY source
            ORDER BY MIN(source_priority)""").fetchall(),
        "methods": db.execute("""SELECT method, COUNT(*) n FROM cluster
            GROUP BY method ORDER BY n DESC""").fetchall(),
        "roles": db.execute("""SELECT role, COUNT(*) n FROM member
            GROUP BY role ORDER BY n DESC""").fetchall(),
        "chosen": db.execute("""SELECT reason, COUNT(*) n FROM decision
            WHERE outcome='canonical' GROUP BY reason ORDER BY n DESC""").fetchall(),
        "review": db.execute("""SELECT verdict, COUNT(*) n FROM review
            GROUP BY verdict ORDER BY n DESC""").fetchall(),
        "sidecars": db.execute("""SELECT f.source,
              COUNT(*) n,
              SUM(EXISTS(SELECT 1 FROM sidecar s WHERE s.file_id=f.id
                         AND s.kind='google_json')) hit
            FROM file f WHERE f.status='extracted' GROUP BY f.source""").fetchall(),
        "coverage": [
            ("A capture time", before_date, files, after_date, assets, ""),
            ("A timezone offset", before_zone, files, after_zone, assets,
             f"{derived_zone} derived from a neighbour or the location"),
            ("A location", before_gps, files, after_gps, assets,
             f"{inferred_gps} inferred from the rest of its day"),
        ],
        "conflicts": _one(db, "SELECT COUNT(*) FROM resolution "
                              "WHERE competing_json LIKE '%date_conflict%'"),
        "written": _one(db, "SELECT COUNT(*) FROM decision WHERE verified_at IS NOT NULL"),
    }


def _bar(pct: float, tone: str) -> str:
    return (f"<div class=bar><div class='fill {tone}' "
            f"style='width:{max(0.6, min(100.0, pct)):.1f}%'></div></div>")


def _render(d: dict) -> str:
    rows = []
    for label, b, bt, a, at, note in d["coverage"]:
        pb = 100.0 * b / bt if bt else 0
        pa = 100.0 * a / at if at else 0
        rows.append(
            f"<tr><th>{html.escape(label)}</th>"
            f"<td class=num>{b:,} / {bt:,}</td><td class=w>{_bar(pb, 'before')}"
            f"<span class=pct>{pb:.1f}%</span></td>"
            f"<td class=num><b>{a:,} / {at:,}</b></td><td class=w>{_bar(pa, 'after')}"
            f"<span class=pct><b>{pa:.1f}%</b></span></td>"
            f"<td class=note>{html.escape(note)}</td></tr>")

    def table(title, data, key, val, fmt=lambda v: f"{v:,}"):
        body = "".join(f"<tr><th>{html.escape(str(r[key]))}</th>"
                       f"<td class=num>{fmt(r[val])}</td></tr>" for r in data)
        return f"<section><h2>{title}</h2><table class=plain>{body}</table></section>"

    sources = "".join(
        f"<tr><th>{html.escape(r['source'])}</th><td class=num>{r['n']:,}</td>"
        f"<td class=num>{r['gb']:.1f} GB</td></tr>" for r in d["sources"])
    sidecars = "".join(
        f"<tr><th>{html.escape(r['source'])}</th>"
        f"<td class=num>{r['hit']:,} / {r['n']:,}</td>"
        f"<td class=num>{100.0 * r['hit'] / r['n'] if r['n'] else 0:.2f}%</td></tr>"
        for r in d["sidecars"])
    chosen = "".join(
        f"<tr><th>{html.escape(_shorten(r['reason']))}</th>"
        f"<td class=num>{r['n']:,}</td></tr>" for r in d["chosen"][:8])
    review = "".join(
        f"<tr><th>{html.escape(r['verdict'])}</th><td class=num>{r['n']:,}</td></tr>"
        for r in d["review"]) or "<tr><th>nothing unresolved</th><td class=num>0</td></tr>"

    reduction = 100.0 * (1 - d["assets"] / d["files"]) if d["files"] else 0
    return f"""<!doctype html>
<meta charset=utf-8><title>photomerge report</title>
<style>
:root {{ --ink:#16161a; --dim:#6b6b76; --line:#e3e3e8; --bg:#fff;
         --before:#c9c9d2; --after:#2f6f4f; }}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme=light]) {{
  --ink:#e9e9ee; --dim:#9a9aa6; --line:#2c2c34; --bg:#131318;
  --before:#3d3d47; --after:#5fae86; }} }}
* {{ box-sizing:border-box }}
body {{ margin:0; padding:40px 16px 72px; background:var(--bg); color:var(--ink);
  font:15px/1.6 ui-sans-serif,-apple-system,system-ui,sans-serif;
  -webkit-font-smoothing:antialiased }}
main {{ max-width:880px; margin:0 auto }}
h1 {{ font-size:22px; margin:0 0 4px; letter-spacing:-.01em }}
.sub {{ color:var(--dim); margin:0 0 36px; font-size:13px }}
h2 {{ font-size:13px; text-transform:uppercase; letter-spacing:.07em;
  color:var(--dim); margin:0 0 10px; font-weight:600 }}
section {{ margin-bottom:34px }}
.head {{ display:flex; gap:32px; flex-wrap:wrap; padding:20px 0 24px;
  border-top:1px solid var(--line); border-bottom:1px solid var(--line);
  margin-bottom:34px }}
.big {{ font-size:30px; font-weight:650; letter-spacing:-.02em; line-height:1.1 }}
.big span {{ font-size:13px; font-weight:400; color:var(--dim); display:block;
  letter-spacing:0; margin-top:3px }}
table {{ border-collapse:collapse; width:100% }}
th {{ text-align:left; font-weight:450 }}
td, th {{ padding:7px 10px 7px 0; border-bottom:1px solid var(--line);
  vertical-align:middle }}
.plain th {{ color:var(--ink) }}
.num {{ text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap }}
.w {{ width:180px }}
.bar {{ height:7px; background:var(--line); border-radius:4px; overflow:hidden;
  display:inline-block; width:110px; vertical-align:middle }}
.fill {{ height:100%; border-radius:4px }}
.fill.before {{ background:var(--before) }}
.fill.after {{ background:var(--after) }}
.pct {{ font-size:12px; color:var(--dim); margin-left:8px;
  font-variant-numeric:tabular-nums }}
.note {{ color:var(--dim); font-size:12.5px }}
.grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(250px,1fr));
  gap:30px }}
p.lede {{ color:var(--dim); font-size:13.5px; margin:-4px 0 14px; max-width:62ch }}
@media (max-width:640px) {{ .w {{ width:auto }} .bar {{ width:64px }} }}
</style>
<main>
<h1>photomerge report</h1>
<p class=sub>{datetime.now().astimezone():%Y-%m-%d %H:%M %Z} &middot; nothing in this
report has been deleted; it describes the catalog</p>

<div class=head>
  <div class=big>{d['files']:,}<span>input files</span></div>
  <div class=big>{d['assets']:,}<span>assets out &mdash; {reduction:.0f}% fewer</span></div>
  <div class=big>{d['dropped'] / GB:.1f} GB<span>reclaimable</span></div>
  <div class=big>{d['kept'] / GB:.1f} GB<span>kept</span></div>
  <div class=big>{d['written']:,}<span>written &amp; verified</span></div>
</div>

<section>
  <h2>Metadata coverage &mdash; before and after</h2>
  <p class=lede>The number this whole exercise is for. <b>Before</b> counts input
  files that knew something about themselves; <b>after</b> counts output assets that
  were given it by harvesting every copy in a cluster.</p>
  <table>
    <tr><td></td><td class=num>before</td><td></td><td class=num>after</td>
        <td></td><td></td></tr>
    {"".join(rows)}
  </table>
</section>

<div class=grid>
  <section><h2>Sources</h2><table class=plain>{sources}</table></section>
  <section><h2>Takeout sidecars matched</h2><table class=plain>{sidecars}</table></section>
  {table("How files were matched", d["methods"], "method", "n")}
  {table("What became of each file", d["roles"], "role", "n")}
  <section><h2>Why the kept file won</h2><table class=plain>{chosen}</table></section>
  <section><h2>Refused, not guessed</h2><table class=plain>{review}</table>
    <p class=lede style="margin-top:10px">Plus {d['conflicts']:,} assets whose copies
    disagreed on the date by more than a day &mdash; the earliest was kept and the
    alternatives recorded.</p></section>
</div>

<p class=note>Ask why any single file ended up where it did:
<code>photomerge explain &lt;filename&gt;</code> &mdash; it answers from the catalog,
so it keeps working after the duplicates are gone.</p>
</main>
"""


def _shorten(reason: str) -> str:
    for key, label in (
        ("only member", "nothing to choose from"),
        ("more pixels", "more pixels"),
        ("more original format", "a more original format"),
        ("larger at equal", "larger at equal dimensions"),
        ("sharpest frame", "sharpest frame of a burst"),
        ("source priority", "source order (a genuine tie)"),
        ("identical on every", "identical on every criterion"),
    ):
        if key in reason:
            return label
    return reason[:48]
