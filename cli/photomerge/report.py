"""The dry-run report and manifest — what a run *would* do, before it does it.

One CSV row per input file, so nothing the tool decided is invisible, plus a
JSON manifest of the same decisions for the later stages to build on.

Neither file resolves metadata.  `own_datetime` and `own_gps` are what each file
claims about *itself*, at the confidence it claims it; harvesting the best value
across a cluster is stage 4 (M5).  Showing a resolved-looking date here would
invite trusting a number no stage has computed yet.
"""

from __future__ import annotations

import csv
import json
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

CSV_NAME = "photomerge_report.csv"
MANIFEST_NAME = "manifest.json"

COLUMNS = [
    "cluster_id", "method", "role", "outcome", "kept",
    "source", "rel_path", "kind", "mime", "dims", "size",
    "cluster_size", "canonical", "reason",
    "final_datetime", "final_offset", "final_gps", "datetime_note", "gps_note",
    "own_datetime", "datetime_from", "own_gps", "gps_from",
    "capture_stem", "content_id", "path",
]

# Best evidence first; `fs` is last because a file's mtime says when it was
# copied, not when it was taken (D11).
DATETIME_SOURCES = ("exif", "quicktime", "xmp", "google_json", "filename", "fs")
GPS_SOURCES = ("exif", "quicktime", "xmp", "google_json")


@dataclass
class ReportStats:
    rows: int = 0
    assets: int = 0
    kept_bytes: int = 0
    photo_duplicates: int = 0
    photo_freed: int = 0
    video_duplicates: int = 0
    video_freed: int = 0
    companions: int = 0
    review: int = 0
    by_source: dict[str, int] = field(default_factory=dict)
    csv_path: Path | None = None
    manifest_path: Path | None = None
    html_path: Path | None = None


def write_report(db: sqlite3.Connection, out_dir: Path) -> ReportStats:
    out_dir.mkdir(parents=True, exist_ok=True)
    stats = ReportStats()
    best_dt, best_gps = _best_claims(db)
    stems = _stems(db)
    final = _resolutions(db)

    rows = db.execute("""
        SELECT c.id AS cluster_id, c.method, m.role, d.outcome, d.reason,
               f.id AS file_id, f.path, f.rel_path, f.source, f.kind, f.mime,
               f.size, f.width, f.height, f.content_id
        FROM member m
        JOIN cluster c ON c.id = m.cluster_id
        JOIN file f ON f.id = m.file_id
        LEFT JOIN decision d ON d.file_id = f.id
        ORDER BY c.id, m.role != 'canonical', f.path
    """).fetchall()

    sizes: dict[int, int] = {}
    canonical_name: dict[int, str] = {}
    for r in rows:
        sizes[r["cluster_id"]] = sizes.get(r["cluster_id"], 0) + 1
        if r["role"] == "canonical":
            canonical_name[r["cluster_id"]] = r["rel_path"]

    manifest: dict[int, dict] = {}
    stats.csv_path = out_dir / CSV_NAME
    with open(stats.csv_path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=COLUMNS)
        writer.writeheader()
        for r in rows:
            dt_value, dt_source = best_dt.get(r["file_id"], ("", ""))
            gps_value, gps_source = best_gps.get(r["file_id"], ("", ""))
            outcome = r["outcome"] or ""
            writer.writerow({
                "cluster_id": r["cluster_id"], "method": r["method"],
                "role": r["role"], "outcome": outcome,
                "kept": "yes" if outcome in ("canonical", "companion") else "no",
                "source": r["source"], "rel_path": r["rel_path"], "kind": r["kind"],
                "mime": r["mime"],
                "dims": f'{r["width"]}x{r["height"]}' if r["width"] else "",
                "size": r["size"], "cluster_size": sizes[r["cluster_id"]],
                "canonical": "" if r["role"] == "canonical"
                             else canonical_name.get(r["cluster_id"], ""),
                "reason": r["reason"] or "",
                **_final_columns(final.get(r["cluster_id"], {})),
                "own_datetime": dt_value, "datetime_from": dt_source,
                "own_gps": gps_value, "gps_from": gps_source,
                "capture_stem": stems.get(r["file_id"], ""),
                "content_id": r["content_id"] or "", "path": r["path"],
            })
            stats.rows += 1
            stats.by_source[r["source"]] = stats.by_source.get(r["source"], 0) + 1

            entry = manifest.setdefault(r["cluster_id"], {
                "method": r["method"], "keep": None, "companions": [], "drop": []})
            item = {"path": r["path"], "source": r["source"], "size": r["size"],
                    "reason": r["reason"] or ""}
            if outcome == "canonical":
                entry["keep"] = item
                stats.assets += 1
                stats.kept_bytes += r["size"]
            elif outcome == "companion":
                entry["companions"].append(item)
                stats.companions += 1
                stats.kept_bytes += r["size"]
            elif outcome == "review":
                entry.setdefault("review", []).append(item)
                stats.review += 1
                stats.kept_bytes += r["size"]
            else:
                entry["drop"].append(item)
                if r["kind"] == "video":
                    stats.video_duplicates += 1
                    stats.video_freed += r["size"]
                else:
                    stats.photo_duplicates += 1
                    stats.photo_freed += r["size"]

    from photomerge.report_html import write_html
    stats.html_path = write_html(db, out_dir / "report.html")

    stats.manifest_path = out_dir / MANIFEST_NAME
    stats.manifest_path.write_text(json.dumps({
        "generated": datetime.now(timezone.utc).isoformat(),
        "stage": "cluster (M2) — exact and pixel tiers only, nothing written",
        "assets": stats.assets,
        "clusters": [{"id": cid, **entry} for cid, entry in sorted(manifest.items())],
    }, ensure_ascii=False, indent=1), encoding="utf-8")
    return stats


def _resolutions(db) -> dict[int, dict[str, tuple[str, str]]]:
    """Stage 4's answers, keyed by cluster."""
    import json as _json

    out: dict[int, dict[str, tuple[str, str]]] = {}
    for r in db.execute(
        "SELECT cluster_id, field, value, competing_json FROM resolution"
    ):
        note = ""
        if r["competing_json"]:
            try:
                note = _json.loads(r["competing_json"]).get("note") or ""
            except ValueError:
                note = ""
        out.setdefault(r["cluster_id"], {})[r["field"]] = (r["value"], note)
    return out


def _final_columns(fields: dict[str, tuple[str, str]]) -> dict[str, str]:
    when = fields.get("datetime_utc", ("", ""))
    offset = fields.get("utc_offset", ("", ""))
    where = fields.get("gps", ("", ""))
    return {
        "final_datetime": when[0], "final_offset": offset[0], "final_gps": where[0],
        # The offset's own note explains where a derived zone came from, which is
        # the part of a resolved date most worth doubting.
        "datetime_note": "; ".join(n for n in (when[1], offset[1]) if n),
        "gps_note": where[1],
    }


def _best_claims(db) -> tuple[dict[int, tuple[str, str]], dict[int, tuple[str, str]]]:
    """The highest-confidence datetime and GPS claim each file makes about itself."""
    dt_rank = {s: i for i, s in enumerate(DATETIME_SOURCES)}
    gps_rank = {s: i for i, s in enumerate(GPS_SOURCES)}
    best_dt: dict[int, tuple[str, str]] = {}
    best_gps: dict[int, tuple[str, str]] = {}
    ordering: dict[int, tuple] = {}

    for r in db.execute(
        "SELECT file_id, field, value, source, confidence FROM meta "
        "WHERE field IN ('datetime_utc','datetime_local','gps')"
    ):
        if r["field"] == "gps":
            key = (gps_rank.get(r["source"], 99), -r["confidence"])
            if key < ordering.get(("g", r["file_id"]), (99, 0)):
                ordering[("g", r["file_id"])] = key
                best_gps[r["file_id"]] = (r["value"], r["source"])
            continue
        # A UTC instant beats a bare wall clock from the same evidence source.
        key = (dt_rank.get(r["source"], 99), 0 if r["field"] == "datetime_utc" else 1,
               -r["confidence"])
        if key < ordering.get(("d", r["file_id"]), (99, 9, 0)):
            ordering[("d", r["file_id"])] = key
            label = r["source"] + ("" if r["field"] == "datetime_utc" else " (local)")
            if r["source"] == "fs":
                label = "mtime (unreliable)"
            best_dt[r["file_id"]] = (r["value"], label)
    return best_dt, best_gps


def _stems(db) -> dict[int, str]:
    return {r["file_id"]: r["value"] for r in db.execute(
        "SELECT file_id, value FROM meta WHERE field = 'capture_stem'")}
