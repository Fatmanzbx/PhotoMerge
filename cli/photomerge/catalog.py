"""The SQLite catalog — schema, connection, and the small helpers stages share.

The catalog is the product; the output tree is a rendering of it (PLAN §1).
All six stages read and write here and nothing else holds state between runs,
which is what makes every stage independently re-runnable.

`meta` is append-only within a run: stage 4 reads competing claims and decides,
it never edits them.  Re-extracting a file clears that file's own rows first,
because re-derivation from the same bytes must be idempotent rather than
accumulate duplicates.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

SCHEMA_VERSION = 4

SCHEMA = """
CREATE TABLE IF NOT EXISTS file (
    id              INTEGER PRIMARY KEY,
    path            TEXT    NOT NULL UNIQUE,
    rel_path        TEXT    NOT NULL,
    source          TEXT    NOT NULL,
    source_priority INTEGER NOT NULL,
    size            INTEGER NOT NULL,
    mtime           REAL    NOT NULL,
    inode           INTEGER,
    ext             TEXT,
    kind            TEXT,               -- image | video | other
    mime            TEXT,
    sha256          TEXT,
    pixel_hash      TEXT,               -- BLAKE2b over oriented RGB pixels
    stream_hash     TEXT,               -- MD5 of the video stream, container ignored
    dhash64         BLOB,               -- 8 bytes, BK-tree pre-filter
    phash256        BLOB,               -- 32 bytes, verification
    width           INTEGER,
    height          INTEGER,
    sharpness       REAL,               -- variance of Laplacian, burst selection
    make            TEXT,
    model           TEXT,
    exposure_key    TEXT,               -- (ExposureTime, FNumber, ISO)
    content_id      TEXT,               -- Apple ContentIdentifier, Live Photo pairing
    status          TEXT    NOT NULL DEFAULT 'scanned',
                                        -- scanned | extracted | skipped | error
    error           TEXT,
    scanned_at      TEXT,
    extracted_at    TEXT
);
CREATE INDEX IF NOT EXISTS file_sha      ON file(sha256);
CREATE INDEX IF NOT EXISTS file_pixel    ON file(pixel_hash);
CREATE INDEX IF NOT EXISTS file_stream   ON file(stream_hash);
CREATE INDEX IF NOT EXISTS file_content  ON file(content_id);
CREATE INDEX IF NOT EXISTS file_status   ON file(status);
CREATE INDEX IF NOT EXISTS file_source   ON file(source);

-- Every claim any evidence source makes, kept side by side.  Stage 4 decides
-- between them; when a resolution turns out wrong the alternative is still here.
CREATE TABLE IF NOT EXISTS meta (
    id         INTEGER PRIMARY KEY,
    file_id    INTEGER NOT NULL REFERENCES file(id) ON DELETE CASCADE,
    field      TEXT    NOT NULL,
    value      TEXT,
    source     TEXT    NOT NULL,   -- exif | xmp | quicktime | google_json
                                   -- | aae | filename | foldername | fs
    confidence REAL    NOT NULL DEFAULT 1.0
);
CREATE INDEX IF NOT EXISTS meta_file  ON meta(file_id, field);
CREATE INDEX IF NOT EXISTS meta_field ON meta(field);

CREATE TABLE IF NOT EXISTS sidecar (
    id           INTEGER PRIMARY KEY,
    file_id      INTEGER NOT NULL REFERENCES file(id) ON DELETE CASCADE,
    kind         TEXT    NOT NULL,   -- google_json | aae | xmp
    path         TEXT    NOT NULL,
    rule         TEXT,               -- which cascade rule matched (PLAN §2)
    payload_json TEXT
);
CREATE INDEX IF NOT EXISTS sidecar_file ON sidecar(file_id);
CREATE UNIQUE INDEX IF NOT EXISTS sidecar_pair ON sidecar(file_id, path);

CREATE TABLE IF NOT EXISTS cluster (
    id         INTEGER PRIMARY KEY,
    method     TEXT NOT NULL,        -- exact | pixel | perceptual | burst
    confidence REAL NOT NULL DEFAULT 1.0
);

CREATE TABLE IF NOT EXISTS member (
    cluster_id   INTEGER NOT NULL REFERENCES cluster(id) ON DELETE CASCADE,
    file_id      INTEGER NOT NULL REFERENCES file(id) ON DELETE CASCADE,
    role         TEXT,               -- canonical | duplicate | burst_sibling | variant
    derived_from INTEGER REFERENCES file(id),
    PRIMARY KEY (cluster_id, file_id)
);
CREATE INDEX IF NOT EXISTS member_file ON member(file_id);

CREATE TABLE IF NOT EXISTS resolution (
    cluster_id     INTEGER NOT NULL REFERENCES cluster(id) ON DELETE CASCADE,
    field          TEXT    NOT NULL,
    value          TEXT,
    source         TEXT,
    confidence     REAL,
    competing_json TEXT,
    PRIMARY KEY (cluster_id, field)
);

-- Pairs that looked alike but that tier D would not confirm.  Kept as pairs
-- rather than as per-file rows: what is unresolved is the *relationship*, not
-- the fate of either file, and both are kept either way.  M7 renders these as
-- contact sheets; until then they are the honest record of what was refused.
CREATE TABLE IF NOT EXISTS review (
    id          INTEGER PRIMARY KEY,
    file_a      INTEGER NOT NULL REFERENCES file(id) ON DELETE CASCADE,
    file_b      INTEGER NOT NULL REFERENCES file(id) ON DELETE CASCADE,
    verdict     TEXT    NOT NULL,
    reason      TEXT,
    checks_json TEXT
);
CREATE INDEX IF NOT EXISTS review_a ON review(file_a);

CREATE TABLE IF NOT EXISTS decision (
    id            INTEGER PRIMARY KEY,
    file_id       INTEGER NOT NULL REFERENCES file(id) ON DELETE CASCADE,
    outcome       TEXT    NOT NULL,   -- canonical | companion | duplicate
                                      -- | burst_sibling | review
    target_path   TEXT,
    reason        TEXT,
    -- The safety invariant of §5b: a file may be unlinked only once the
    -- decision that replaces it carries `verified_at`. That makes "delete the
    -- duplicate" structurally dependent on "its replacement is provably good"
    -- rather than on the order the stages happened to run in.
    superseded_by INTEGER REFERENCES decision(id),
    verified_at   TEXT
);
CREATE INDEX IF NOT EXISTS decision_file ON decision(file_id);
"""


def open_catalog(path: str | Path, *, create: bool = True) -> sqlite3.Connection:
    """Open (and on first use create) the catalog at `path`."""
    path = Path(path).expanduser()
    if not create and not path.exists():
        raise FileNotFoundError(f"no catalog at {path} — run `photomerge scan` first")
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=60.0, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode = WAL")
    db.execute("PRAGMA synchronous = NORMAL")
    db.execute("PRAGMA foreign_keys = ON")
    db.executescript(SCHEMA)
    _migrate(db)
    have = db.execute("PRAGMA user_version").fetchone()[0]
    if have <= SCHEMA_VERSION:
        # Every change so far has been additive, and the schema script above is
        # all `IF NOT EXISTS`, so an older catalog is already up to date by the
        # time we get here.  Re-extracting 20k files to gain one table would be
        # a poor trade.
        db.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
    else:
        raise SystemExit(
            f"catalog {path} is schema v{have}, this build speaks v{SCHEMA_VERSION}. "
            "It was written by a newer photomerge; upgrade rather than downgrade."
        )
    return db


def _migrate(db: sqlite3.Connection) -> None:
    """Additive column migrations, for catalogs written by an earlier build.

    Re-extracting 23,000 files to gain a column would be a poor trade, so each
    change here has to be one that costs nothing to apply to existing rows.
    """
    columns = {r["name"] for r in db.execute("PRAGMA table_info(decision)")}
    if "verified_at" not in columns:
        db.execute("ALTER TABLE decision ADD COLUMN verified_at TEXT")
    columns = {r["name"] for r in db.execute("PRAGMA table_info(file)")}
    if "stream_hash" not in columns:
        db.execute("ALTER TABLE file ADD COLUMN stream_hash TEXT")


def counts_by_status(db: sqlite3.Connection) -> dict[str, int]:
    return {
        r["status"]: r["n"]
        for r in db.execute("SELECT status, COUNT(*) AS n FROM file GROUP BY status")
    }
