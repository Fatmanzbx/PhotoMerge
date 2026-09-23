"""Command line.  M1 ships `scan`, `extract` and `status`.

Every subcommand is re-runnable and does nothing outside the catalog — no output
tree is written until stage 5, which does not exist yet.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

from photomerge import __version__
from photomerge.catalog import open_catalog

DEFAULT_CATALOG = "catalog.sqlite"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="photomerge",
        description="Merge N photo sources into one library, keeping the best "
                    "pixels and the union of the metadata.",
    )
    parser.add_argument("--version", action="version", version=f"photomerge {__version__}")
    parser.add_argument("-c", "--catalog", default=DEFAULT_CATALOG,
                        help=f"catalog path (default: {DEFAULT_CATALOG})")
    sub = parser.add_subparsers(dest="command", required=True)

    p_scan = sub.add_parser("scan", help="stage 1 — walk the sources into the catalog")
    p_scan.add_argument("--src", action="append", required=True, metavar="DIR",
                        help="a source directory; repeat, highest priority first "
                             "(order is a tiebreak only, never a quality override)")
    p_scan.add_argument("--force", action="store_true",
                        help="re-read every file even if unchanged since the last scan")
    p_scan.set_defaults(func=cmd_scan)

    p_extract = sub.add_parser("extract", help="stage 2 — hash and read metadata")
    p_extract.add_argument("--workers", type=int, default=0,
                           help="decode processes (default: CPU count - 1)")
    p_extract.add_argument("--limit", type=int, help="stop after N files, for a trial run")
    p_extract.add_argument("--force", action="store_true",
                           help="re-extract files already extracted")
    p_extract.set_defaults(func=cmd_extract)

    p_cluster = sub.add_parser(
        "cluster", help="stage 3 — group files that are the same photo")
    p_cluster.add_argument("--radius", type=int, default=4, metavar="N",
                           help="dHash Hamming radius for perceptual candidates "
                                "(default 4; see PLAN §3.1-C for the calibration)")
    p_cluster.add_argument("--keep-bursts", action="store_true",
                           help="leave every burst frame as its own asset")
    p_cluster.add_argument("--no-perceptual", action="store_true",
                           help="certain tiers only — equal bytes and equal pixels")
    p_cluster.set_defaults(func=cmd_cluster)

    p_resolve = sub.add_parser(
        "resolve", help="stage 4 — decide each asset's date, place and camera")
    p_resolve.add_argument("--prior", metavar="CATALOG",
                           help="a previous round's catalog — this file's embedded "
                                "dates are that round's conclusions, so resolve from "
                                "what its sources originally claimed instead")
    p_resolve.add_argument("--no-infer-location", action="store_true",
                           help="do not infer a missing location from the rest of "
                                "its day")
    p_resolve.add_argument("--location-radius", type=float, default=25.0, metavar="KM",
                           help="how tightly a day's locations must cluster to count "
                                "as one city (default 25)")
    p_resolve.set_defaults(func=cmd_resolve)

    p_report = sub.add_parser(
        "report", help="write the dry-run report and manifest")
    p_report.add_argument("--out", default=".", metavar="DIR",
                          help="where to write the report (default: here)")
    p_report.set_defaults(func=cmd_report)

    p_write = sub.add_parser(
        "write", help="stage 5 — render the catalog into an output tree")
    p_write.add_argument("--out", required=True, metavar="DIR",
                         help="the output tree, e.g. ~/PhotoMerge/RESULT")
    p_write.add_argument("--apply", action="store_true",
                         help="actually write; without it nothing moves")
    p_write.add_argument("--move", action="store_true",
                         help="move instead of copy (needs no free space)")
    p_write.add_argument("--keep-bursts", action="store_true",
                         help="also write every burst frame, not just the sharpest")
    p_write.add_argument("--limit", type=int, metavar="N",
                         help="write only the first N assets, for a trial run")
    p_write.add_argument("--no-verify", action="store_true",
                         help="skip re-reading each written file (not advised)")
    p_write.set_defaults(func=cmd_write)

    p_live = sub.add_parser(
        "livephotos", help="stage 5c — pair written stills and movies as Live Photos")
    p_live.add_argument("--out", required=True, metavar="DIR")
    p_live.add_argument("--apply", action="store_true")
    p_live.add_argument("--limit", type=int, metavar="N",
                        help="only the first N pairs — validate before running all")
    p_live.set_defaults(func=cmd_livephotos)

    p_trash = sub.add_parser(
        "trash", help="stage 5b — move superseded files into RESULT/.trash/")
    p_trash.add_argument("--out", required=True, metavar="DIR")
    p_trash.add_argument("--apply", action="store_true",
                         help="actually move them; without it nothing moves")
    p_trash.set_defaults(func=cmd_trash)

    p_undo = sub.add_parser(
        "undo", help="reverse a write, from the manifest it wrote as it went")
    p_undo.add_argument("--out", required=True, metavar="DIR")
    p_undo.add_argument("--apply", action="store_true")
    p_undo.set_defaults(func=cmd_undo)

    p_restore = sub.add_parser(
        "restore", help="put everything in .trash/ back where it came from")
    p_restore.add_argument("--out", required=True, metavar="DIR")
    p_restore.add_argument("--apply", action="store_true")
    p_restore.set_defaults(func=cmd_restore)

    p_reclaim = sub.add_parser(
        "reclaim", help="unlink .trash/ — irreversible, and the only step that is")
    p_reclaim.add_argument("--out", required=True, metavar="DIR")
    p_reclaim.add_argument("--confirm", action="store_true",
                           help="required; without it this only reports")
    p_reclaim.set_defaults(func=cmd_reclaim)

    p_review = sub.add_parser(
        "review", help="contact sheets for the decisions worth looking at")
    p_review.add_argument("--out", default="review", metavar="DIR",
                          help="where to write the sheets (default: review/)")
    p_review.add_argument("--sample", type=int, default=12,
                          help="how many of each kind to render (default 12)")
    p_review.set_defaults(func=cmd_review)

    p_explain = sub.add_parser(
        "explain", help="why did this file end up where it did?")
    p_explain.add_argument("file", help="a path, a filename, or any fragment of one — "
                                        "from either the sources or the output")
    p_explain.set_defaults(func=cmd_explain)

    p_status = sub.add_parser("status", help="what the catalog knows so far")
    p_status.add_argument("--errors", action="store_true", help="list files that failed")
    p_status.set_defaults(func=cmd_status)

    args = parser.parse_args(argv)
    return args.func(args)


def cmd_scan(args) -> int:
    from photomerge.scan import scan

    db = open_catalog(args.catalog)
    started = time.monotonic()
    stats = scan(db, [Path(s) for s in args.src], force=args.force, progress=_tick("scanned"))
    _clear()
    print(f"scanned {stats.seen} entries in {time.monotonic() - started:.1f}s")
    print(f"  added {stats.added}   updated {stats.updated}   "
          f"unchanged {stats.unchanged}   skipped {stats.skipped}")
    if stats.repriced:
        print(f"  source priority updated on {stats.repriced} unchanged files")
    if stats.by_skip_reason:
        for reason, n in sorted(stats.by_skip_reason.items(), key=lambda kv: -kv[1]):
            print(f"    skip: {reason}: {n}")
    for source, total in stats.sidecar_total.items():
        hit = stats.sidecar_hit.get(source, 0)
        rate = f"{100.0 * hit / total:.2f}%" if total else "n/a"
        print(f"  sidecars matched in {source}: {hit}/{total} ({rate})")
    for rule, n in sorted(stats.by_rule.items(), key=lambda kv: -kv[1]):
        print(f"    via {rule}: {n}")
    print(f"\nnext: photomerge -c {args.catalog} extract")
    return 0


def cmd_extract(args) -> int:
    from photomerge.exiftool import ExifToolMissing
    from photomerge.extract import extract

    db = open_catalog(args.catalog, create=False)
    started = time.monotonic()
    try:
        stats = extract(db, workers=args.workers, limit=args.limit,
                        force=args.force, progress=_tick("extracted"))
    except ExifToolMissing as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    _clear()
    elapsed = time.monotonic() - started
    rate = stats.done / elapsed if elapsed else 0
    print(f"extracted {stats.done}/{stats.total} files in {elapsed:.1f}s ({rate:.1f}/s)")
    print(f"  metadata claims recorded: {stats.claims}")
    if stats.errors:
        print(f"  files with problems: {stats.errors}")
        for reason, n in sorted(stats.by_error.items(), key=lambda kv: -kv[1]):
            print(f"    {reason}: {n}")
        print(f"  list them with: photomerge -c {args.catalog} status --errors")
    return 0


def cmd_cluster(args) -> int:
    from photomerge.cluster import cluster

    db = open_catalog(args.catalog, create=False)
    pending = db.execute("SELECT COUNT(*) FROM file WHERE status='scanned'").fetchone()[0]
    if pending:
        print(f"warning: {pending} files are scanned but not extracted and will be "
              f"left out — run `photomerge -c {args.catalog} extract` first",
              file=sys.stderr)
    started = time.monotonic()
    stats = cluster(db, radius=args.radius, perceptual=not args.no_perceptual,
                    keep_bursts=args.keep_bursts, progress=_verify_tick())
    _clear()
    print(f"clustered {stats.files} files into {stats.clusters} assets "
          f"in {time.monotonic() - started:.1f}s")
    for method, n in sorted(stats.by_method.items(), key=lambda kv: -kv[1]):
        print(f"    {method}: {n}")
    if stats.burst_siblings:
        print(f"  burst frames collapsed {stats.burst_siblings:5d} "
              f"(by sharpness; --keep-bursts keeps them)")
    print(f"\n  photo duplicates   {stats.duplicates:7d}   "
          f"{stats.freed_bytes / 1073741824:6.1f} GB removable")
    print(f"  video duplicates   {stats.video_duplicates:7d}   "
          f"{stats.video_freed_bytes / 1073741824:6.1f} GB — flagged, never deleted (§5)")
    print(f"  companions paired  {stats.companions:7d}")
    for rule, n in sorted(stats.by_companion_rule.items(), key=lambda kv: -kv[1]):
        print(f"    via {rule}: {n}")
    if stats.candidates:
        print(f"\n  perceptual candidates {stats.candidates:6d} (radius {args.radius})")
        print(f"  verified              {stats.verified:6d}")
        for outcome, n in sorted(stats.merged_by_tier.items(), key=lambda kv: -kv[1]):
            print(f"    merged as {outcome}: {n}")
    if stats.review:
        print(f"  needs review       {stats.review:7d}")
        for reason, n in sorted(stats.by_review_reason.items(), key=lambda kv: -kv[1]):
            print(f"    {reason}: {n}")
    print(f"\nnext: photomerge -c {args.catalog} report")
    return 0


def cmd_resolve(args) -> int:
    from photomerge.resolve import resolve

    db = open_catalog(args.catalog, create=False)
    if not db.execute("SELECT COUNT(*) FROM cluster").fetchone()[0]:
        print(f"error: nothing clustered yet — run "
              f"`photomerge -c {args.catalog} cluster`", file=sys.stderr)
        return 2
    started = time.monotonic()
    stats = resolve(db, infer_location=not args.no_infer_location,
                    location_radius_km=args.location_radius, prior=args.prior,
                    progress=_tick("resolved"))
    _clear()
    print(f"resolved {stats.clusters} assets in {time.monotonic() - started:.1f}s")
    if stats.from_prior:
        print(f"  {stats.from_prior} files resolved from their sources' original "
              f"claims, not the dates we wrote")
    print(f"  capture time   {stats.resolved_time:7d}")
    print(f"  location       {stats.resolved_gps:7d}")
    if stats.gps_inferred or stats.gps_day_too_wide:
        print(f"    inferred                    {stats.gps_inferred:7d}")
        print(f"      from a fix minutes away   {stats.gps_from_travel:7d}")
        print(f"    declined, day spans too far {stats.gps_day_too_wide:7d}")
        print(f"    declined, too far in time   {stats.gps_gap_too_wide:7d}")
        print(f"    no located photo that day   {stats.gps_no_anchor:7d}")
    print(f"\n  timezone known from:")
    print(f"    the file's own offset tag  {stats.tz_from_offset:7d}")
    print(f"    the location               {stats.tz_from_gps:7d}")
    print(f"    the nearest dated photo    {stats.tz_from_neighbour:7d}")
    print(f"    still unknown              {stats.tz_unknown:7d}")
    if stats.batch_claims_downgraded:
        print(f"\n  {stats.batch_claims_downgraded} claims sat on batch timestamps "
              f"and were downgraded")
    print(f"\n  timezone artifacts {stats.tz_artifacts:5d}   (not conflicts — the same "
          f"instant read in two zones)")
    print(f"  time conflicts {stats.conflicts:7d}   escalated to review: {stats.review}")
    print(f"  gps conflicts  {stats.gps_conflicts:7d}   escalated to review: {stats.gps_review}")
    for note, n in sorted(stats.by_note.items(), key=lambda kv: -kv[1])[:6]:
        print(f"    {note[:64]}: {n}")
    print(f"\nnext: photomerge -c {args.catalog} report")
    return 0


def cmd_report(args) -> int:
    from photomerge.report import write_report

    db = open_catalog(args.catalog, create=False)
    if not db.execute("SELECT COUNT(*) FROM cluster").fetchone()[0]:
        print(f"error: nothing clustered yet — run "
              f"`photomerge -c {args.catalog} cluster`", file=sys.stderr)
        return 2
    stats = write_report(db, Path(args.out))

    gb = 1073741824
    print(f"{stats.rows} input files -> {stats.assets} assets "
          f"+ {stats.companions} companions")
    print(f"\n  photo duplicates {stats.photo_duplicates:7d}   "
          f"{stats.photo_freed / gb:6.1f} GB removable")
    print(f"  video duplicates {stats.video_duplicates:7d}   "
          f"{stats.video_freed / gb:6.1f} GB flagged only — no video is ever "
          f"deleted (§5)")
    if stats.review:
        print(f"  needs review     {stats.review:7d}")
    print(f"  kept             {stats.kept_bytes / gb:9.1f} GB")
    print(f"\n  {stats.csv_path}")
    print(f"  {stats.manifest_path}")
    if stats.html_path:
        print(f"  {stats.html_path}   <- open this one first")
    print("\nNothing has been written outside the catalog and these two files. "
          "Read the CSV before going further:\n"
          "  cluster_size > 1  is a merge decision\n"
          "  reason            why that file won or lost\n"
          "  datetime_from     'mtime (unreliable)' means the date is a guess")
    return 0


def cmd_write(args) -> int:
    from photomerge.write import write

    db = open_catalog(args.catalog, create=False)
    if not db.execute("SELECT COUNT(*) FROM resolution").fetchone()[0]:
        print(f"error: nothing resolved yet — run "
              f"`photomerge -c {args.catalog} resolve`", file=sys.stderr)
        return 2
    started = time.monotonic()
    stats = write(db, Path(args.out).expanduser(), apply=args.apply, move=args.move,
                  verify=not args.no_verify, keep_bursts=args.keep_bursts,
                  limit=args.limit,
                  progress=_write_tick())
    _clear()
    gb = 1073741824
    verb = "would write" if not args.apply else "wrote"
    print(f"{verb} {stats.files} files for {stats.assets} assets "
          f"({stats.bytes_needed / gb:.1f} GB) in {time.monotonic() - started:.1f}s")
    for kind, n in sorted(stats.by_kind.items(), key=lambda kv: -kv[1]):
        print(f"    {kind}: {n}")
    if not args.apply:
        print(f"\nNothing was written. Target paths are recorded in the catalog; "
              f"see the `target_path` column via `photomerge report`.")
        print(f"Re-run with --apply to write into {args.out}")
        return 0
    print(f"\n  copied {stats.copied}   moved {stats.moved}   "
          f"metadata embedded {stats.embedded}   verified {stats.verified}")
    if stats.failures:
        print(f"\n  FAILURES: {len(stats.failures)}", file=sys.stderr)
        for line in stats.failures[:10]:
            print(f"    {line}", file=sys.stderr)
        return 1
    print(f"\n  every written file re-read and confirmed byte-identical in pixels")
    return 0


def cmd_livephotos(args) -> int:
    from photomerge.livephotos import pair_live_photos

    db = open_catalog(args.catalog, create=False)
    stats = pair_live_photos(db, Path(args.out).expanduser(), apply=args.apply,
                             limit=args.limit)
    print(f"{stats.pairs} still+movie pairs in the output")
    print(f"  already Live Photos      {stats.already_paired:6d}")
    print(f"  {'paired' if args.apply else 'would pair':24s} "
          f"{stats.paired if args.apply else stats.pairs - stats.already_paired:6d}")
    if stats.remuxed:
        print(f"  motion lifted from .MP   {stats.remuxed:6d}")
    if stats.skipped:
        print(f"  skipped                  {stats.skipped:6d}")
    for note, n in sorted(stats.notes.items(), key=lambda kv: -kv[1]):
        print(f"    {note}: {n}")
    for line in stats.failures[:10]:
        print(f"  FAILED {line}", file=sys.stderr)
    if not args.apply:
        print(f"\nRe-run with --apply. Validate on a few first: --limit 5")
    return 1 if stats.failures else 0


def cmd_trash(args) -> int:
    from photomerge.reclaim import stage

    db = open_catalog(args.catalog, create=False)
    stats = stage(db, Path(args.out).expanduser(), apply=args.apply)
    gb = 1073741824
    verb = "would stage" if not args.apply else "staged"
    print(f"{verb} {stats.eligible if not args.apply else stats.staged} superseded files"
          + (f" ({stats.bytes_staged / gb:.1f} GB)" if args.apply else ""))
    if stats.missing:
        print(f"  {stats.missing} already gone from the source tree")
    if stats.blocked:
        print(f"\n  held back {stats.blocked}:")
        for why, n in sorted(stats.blocked_reasons.items(), key=lambda kv: -kv[1]):
            print(f"    {n}: {why}")
        print("  Nothing is staged until its replacement is written and verified.")
    for line in stats.failures[:10]:
        print(f"  FAILED {line}", file=sys.stderr)
    if not args.apply:
        print(f"\nRe-run with --apply to move them into {args.out}/.trash/")
    else:
        print(f"\nReview {args.out} now. `photomerge restore --out {args.out} --apply` "
              f"undoes this;\n`photomerge reclaim --out {args.out} --confirm` makes it "
              f"permanent.")
    return 1 if stats.failures else 0


def cmd_undo(args) -> int:
    from photomerge.write import undo_write

    db = open_catalog(args.catalog, create=False)
    stats = undo_write(db, Path(args.out).expanduser(), apply=args.apply)
    verb = "would reverse" if not args.apply else "reversed"
    print(f"{verb} {stats.reversed} moves and {'would remove' if not args.apply else 'removed'} "
          f"{stats.deleted} copies")
    if stats.blocked:
        print(f"\n  left alone {stats.blocked}:")
        for why, n in sorted(stats.reasons.items(), key=lambda kv: -kv[1]):
            print(f"    {n}: {why}")
    for line in stats.failures[:10]:
        print(f"  {line}", file=sys.stderr)
    if not args.apply:
        print("\nRe-run with --apply.")
    else:
        print("\nStage 5 reversed. Anything already in .trash/ comes back with "
              "`restore`;\nanything `reclaim` unlinked is gone.")
    return 1 if stats.failures else 0


def cmd_restore(args) -> int:
    from photomerge.reclaim import restore

    db = open_catalog(args.catalog, create=False)
    n = restore(db, Path(args.out).expanduser(), apply=args.apply)
    print(f"{'restored' if args.apply else 'would restore'} {n} files from .trash/")
    return 0


def cmd_reclaim(args) -> int:
    from photomerge.reclaim import reclaim

    db = open_catalog(args.catalog, create=False)
    out = Path(args.out).expanduser()
    stats = reclaim(db, out, confirm=args.confirm)
    gb = 1073741824
    if not stats.files:
        print(f"nothing staged in {out}/.trash/")
        return 0
    if not args.confirm:
        print(f"{stats.files} files ({stats.bytes_freed / gb:.1f} GB) are staged in "
              f"{out}/.trash/")
        print("\nThis step is irreversible and it ends the analysis: re-clustering at "
              "a different\nthreshold needs these pixels and they will be gone. "
              "Review the output first.")
        print(f"\nRe-run with --confirm to unlink them.")
        return 0
    print(f"unlinked {stats.files} files, freed {stats.bytes_freed / gb:.1f} GB")
    for line in stats.failures[:10]:
        print(f"  FAILED {line}", file=sys.stderr)
    return 1 if stats.failures else 0


def cmd_review(args) -> int:
    from photomerge.review import write_review

    db = open_catalog(args.catalog, create=False)
    if not db.execute("SELECT COUNT(*) FROM cluster").fetchone()[0]:
        print("error: nothing clustered yet", file=sys.stderr)
        return 2
    out = Path(args.out)
    items = write_review(db, out, sample=args.sample)
    merges = [i for i in items if i.kind == "merge"]
    print(f"wrote {len(items)} contact sheets to {out}/")
    if merges:
        print(f"  weakest merge evidence: SSIM {merges[0].score:.3f}"
              if merges[0].score < 1.0 else "  weakest merges rendered")
    print(f"\nopen {out / 'index.html'}")
    return 0


def cmd_explain(args) -> int:
    from photomerge.explain import explain

    db = open_catalog(args.catalog, create=False)
    for line in explain(db, args.file):
        print(line)
    return 0


def cmd_status(args) -> int:
    db = open_catalog(args.catalog, create=False)

    if args.errors:
        rows = db.execute(
            "SELECT path, status, error FROM file WHERE error IS NOT NULL ORDER BY path"
        ).fetchall()
        for r in rows:
            print(f"{r['status']:9s} {r['error']}\n          {r['path']}")
        print(f"\n{len(rows)} files with a recorded problem")
        return 0

    _table(db, "by source", """
        SELECT source AS k, COUNT(*) AS n,
               SUM(size) / 1073741824.0 AS gb
        FROM file WHERE status != 'skipped' GROUP BY source ORDER BY source_priority
    """, size=True)
    _table(db, "by kind", """
        SELECT kind || ' / ' || COALESCE(mime, '?') AS k, COUNT(*) AS n,
               SUM(size) / 1073741824.0 AS gb
        FROM file WHERE status != 'skipped' GROUP BY k ORDER BY n DESC
    """, size=True)
    _table(db, "by status", "SELECT status AS k, COUNT(*) AS n FROM file GROUP BY status")

    media = db.execute("SELECT COUNT(*) FROM file WHERE status='extracted'").fetchone()[0]
    if not media:
        print("\nnothing extracted yet — run `photomerge extract`")
        return 0

    print(f"\nmetadata coverage ({media} extracted files)")
    for label, sql in (
        ("any capture time", "SELECT COUNT(DISTINCT file_id) FROM meta WHERE field IN "
                             "('datetime_local','datetime_utc') AND source != 'fs'"),
        ("  from exif/quicktime", "SELECT COUNT(DISTINCT file_id) FROM meta WHERE field IN "
                                  "('datetime_local','datetime_utc') AND source IN ('exif','quicktime')"),
        ("  only from sidecar", "SELECT COUNT(DISTINCT file_id) FROM meta m WHERE field IN "
                                "('datetime_local','datetime_utc') AND source='google_json' "
                                "AND NOT EXISTS (SELECT 1 FROM meta x WHERE x.file_id=m.file_id "
                                "AND x.field IN ('datetime_local','datetime_utc') "
                                "AND x.source IN ('exif','quicktime'))"),
        ("  only from filename", "SELECT COUNT(DISTINCT file_id) FROM meta m WHERE field IN "
                                 "('datetime_local','datetime_utc') AND source='filename' "
                                 "AND NOT EXISTS (SELECT 1 FROM meta x WHERE x.file_id=m.file_id "
                                 "AND x.field IN ('datetime_local','datetime_utc') "
                                 "AND x.source IN ('exif','quicktime','google_json'))"),
        ("  mtime only (unreliable)", "SELECT COUNT(*) FROM file f WHERE f.status='extracted' "
                                      "AND NOT EXISTS (SELECT 1 FROM meta x WHERE x.file_id=f.id "
                                      "AND x.field IN ('datetime_local','datetime_utc') "
                                      "AND x.source != 'fs')"),
        ("utc offset known", "SELECT COUNT(DISTINCT file_id) FROM meta WHERE field='utc_offset'"),
        ("gps", "SELECT COUNT(DISTINCT file_id) FROM meta WHERE field='gps'"),
        ("  only from sidecar", "SELECT COUNT(DISTINCT file_id) FROM meta m WHERE field='gps' "
                                "AND source='google_json' AND NOT EXISTS (SELECT 1 FROM meta x "
                                "WHERE x.file_id=m.file_id AND x.field='gps' AND x.source!='google_json')"),
        ("apple ContentIdentifier", "SELECT COUNT(*) FROM file WHERE content_id IS NOT NULL"),
        ("album membership", "SELECT COUNT(DISTINCT file_id) FROM meta WHERE field='album'"),
    ):
        n = db.execute(sql).fetchone()[0]
        print(f"  {label:26s} {n:7d}  {100.0 * n / media:5.1f}%")

    print("\nduplicate signal (pre-clustering)")
    for label, sql in (
        ("distinct sha256", "SELECT COUNT(DISTINCT sha256) FROM file WHERE sha256 IS NOT NULL"),
        ("distinct pixel_hash", "SELECT COUNT(DISTINCT pixel_hash) FROM file WHERE pixel_hash IS NOT NULL"),
        ("files with pixel_hash", "SELECT COUNT(*) FROM file WHERE pixel_hash IS NOT NULL"),
        ("distinct capture stems", "SELECT COUNT(DISTINCT value) FROM meta WHERE field='capture_stem'"),
    ):
        print(f"  {label:26s} {db.execute(sql).fetchone()[0]:7d}")
    return 0


def _table(db, title, sql, size=False) -> None:
    rows = db.execute(sql).fetchall()
    if not rows:
        return
    print(f"\n{title}")
    for r in rows:
        line = f"  {str(r['k']):32s} {r['n']:7d}"
        if size and r["gb"] is not None:
            line += f"  {r['gb']:8.1f} GB"
        print(line)


def _write_tick():
    last = [0.0]

    def progress(stats) -> None:
        now = time.monotonic()
        if now - last[0] < 0.3:
            return
        last[0] = now
        done = stats.copied + stats.moved
        print(f"\r  writing {done}/{stats.files} ...", end="", file=sys.stderr, flush=True)

    return progress


def _verify_tick():
    """Tier D is the long pole — several minutes on a real library — so it has to
    say something while it works."""
    last = [0.0]

    def progress(stats) -> None:
        now = time.monotonic()
        if now - last[0] < 0.5 or not stats.candidates:
            return
        last[0] = now
        done, total = stats.verified, stats.candidates
        share = 100.0 * done / total if total else 0
        print(f"\r  verifying candidates {done}/{total} ({share:.0f}%) ...",
              end="", file=sys.stderr, flush=True)

    return progress


def _tick(verb: str):
    last = [0.0]

    def progress(stats) -> None:
        now = time.monotonic()
        if now - last[0] < 0.2:
            return
        last[0] = now
        n = (getattr(stats, "seen", None) or getattr(stats, "done", None)
             or getattr(stats, "clusters", 0))
        total = getattr(stats, "total", 0)
        suffix = f"/{total}" if total else ""
        print(f"\r  {verb} {n}{suffix} ...", end="", file=sys.stderr, flush=True)

    return progress


def _clear() -> None:
    print("\r" + " " * 60 + "\r", end="", file=sys.stderr, flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
