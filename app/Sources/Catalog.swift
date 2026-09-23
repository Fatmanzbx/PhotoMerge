import Foundation
import SQLite3

/// The catalog is the product (PLAN §6). Every fingerprint and every decision is
/// persisted; the UI is a view over this, never over in-memory state.
final class Catalog {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "catalog.writer")
    let url: URL

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            throw Err.open(String(cString: sqlite3_errmsg(db)))
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit { if db != nil { sqlite3_close(db) } }

    enum Err: Error { case open(String), sql(String) }

    // MARK: schema

    private func migrate() throws {
        try run("""
        CREATE TABLE IF NOT EXISTS source(
            id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE,
            added_at REAL NOT NULL, priority INTEGER NOT NULL DEFAULT 0, exclude TEXT);

        CREATE TABLE IF NOT EXISTS file(
            id INTEGER PRIMARY KEY,
            source_id INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
            path TEXT NOT NULL UNIQUE, rel_path TEXT NOT NULL,
            size INTEGER NOT NULL, mtime REAL NOT NULL,
            kind TEXT, mime TEXT, ext TEXT,
            sha256 TEXT, pixel_hash TEXT, dhash64 INTEGER, thumb BLOB,
            duration REAL, frames BLOB, ev REAL,
            utc_instant REAL, utc_source TEXT, sidecar TEXT, sidecar_rule TEXT, sc_lat REAL, sc_lon REAL, name_local TEXT, name_utc REAL, name_rule TEXT, album TEXT, folder_year INTEGER, title TEXT, content_id TEXT, motion TEXT,
            width INTEGER, height INTEGER,
            captured_at TEXT, utc_offset TEXT, lat REAL, lon REAL,
            make TEXT, model TEXT,
            state TEXT NOT NULL DEFAULT 'scanned');

        CREATE INDEX IF NOT EXISTS file_sha   ON file(sha256);
        CREATE INDEX IF NOT EXISTS file_pixel ON file(pixel_hash);
        CREATE INDEX IF NOT EXISTS file_state ON file(state);

        CREATE TABLE IF NOT EXISTS cluster(
            id INTEGER PRIMARY KEY, method TEXT NOT NULL, size INTEGER NOT NULL DEFAULT 0,
            wasted INTEGER NOT NULL DEFAULT 0);

        CREATE TABLE IF NOT EXISTS member(
            cluster_id INTEGER NOT NULL REFERENCES cluster(id) ON DELETE CASCADE,
            file_id INTEGER NOT NULL REFERENCES file(id) ON DELETE CASCADE,
            role TEXT NOT NULL, reason TEXT,
            PRIMARY KEY(cluster_id, file_id));

        CREATE INDEX IF NOT EXISTS member_file ON member(file_id);

        CREATE TABLE IF NOT EXISTS resolution(
            cluster_id INTEGER PRIMARY KEY REFERENCES cluster(id) ON DELETE CASCADE,
            local_time TEXT, time_source TEXT,
            utc_offset TEXT, zone_source TEXT,
            lat REAL, lon REAL, place_source TEXT,
            instant REAL);

        -- A timezone a person chose from a ballot. Keyed by day, because a zone is
        -- a property of a day, not of a photograph. Survives re-analysis: the files
        -- may be rescanned and recluster into different ids, but the day stands.
        CREATE TABLE IF NOT EXISTS zone_pick(
            day INTEGER PRIMARY KEY, utc_offset TEXT NOT NULL, chosen_at REAL NOT NULL);

        -- The dials. Stored here, not in preferences, because the stored groups and
        -- resolutions were produced by these values: they travel together.
        CREATE TABLE IF NOT EXISTS setting(key TEXT PRIMARY KEY, value TEXT NOT NULL);

        -- The copy a person chose to keep, by content hash: whichever group it
        -- lands in after a regroup or rescan, it is the one kept.
        CREATE TABLE IF NOT EXISTS keeper(sha TEXT PRIMARY KEY, chosen_at REAL NOT NULL);

        -- Duplicates moved to the Trash by Tidy, and where each went, to put back.
        CREATE TABLE IF NOT EXISTS trashed(file_id INTEGER PRIMARY KEY, sha TEXT, original TEXT NOT NULL, trash_path TEXT NOT NULL, at REAL NOT NULL);

        -- A day and/or place a person typed in for a photograph that had none.
        CREATE TABLE IF NOT EXISTS manual_fact(sha TEXT PRIMARY KEY, day TEXT, lat REAL, lon REAL, set_at REAL NOT NULL);

        -- "Everything in this folder / between these days was taken here": a place
        -- a person gave, used only where no evidence places a photograph.
        CREATE TABLE IF NOT EXISTS place_rule(
            id INTEGER PRIMARY KEY, folder TEXT, day_from INTEGER, day_to INTEGER,
            lat REAL NOT NULL, lon REAL NOT NULL, label TEXT NOT NULL, created REAL NOT NULL);

        -- A timezone a person corrected on one photograph, keeping its instant:
        -- the file's own offset was contradicted by where and when it was taken.
        CREATE TABLE IF NOT EXISTS zone_fix(sha TEXT PRIMARY KEY, utc_offset TEXT NOT NULL, chosen_at REAL NOT NULL);

        -- The manifest of a written copy: one row per file written, stamped
        -- verified_at only after the written file was read back and matched.
        CREATE TABLE IF NOT EXISTS output(
            file_id INTEGER PRIMARY KEY, cluster_id INTEGER NOT NULL, role TEXT NOT NULL,
            source TEXT NOT NULL, target TEXT NOT NULL, root TEXT NOT NULL,
            state TEXT NOT NULL, written_sha TEXT, error TEXT, verified_at REAL);

        -- Every tier C candidate from the last grouping, and what became of it.
        CREATE TABLE IF NOT EXISTS pair(
            a INTEGER NOT NULL, b INTEGER NOT NULL, distance INTEGER NOT NULL,
            outcome TEXT NOT NULL, mae_hi REAL, mae_lo REAL, PRIMARY KEY(a, b));

        -- A person's verdict on a pair. Keyed by content hash, not file id: ids
        -- change when a folder is rescanned, and the decision must outlive that.
        CREATE TABLE IF NOT EXISTS pair_decision(
            sha_a TEXT NOT NULL, sha_b TEXT NOT NULL, same INTEGER NOT NULL,
            decided_at REAL NOT NULL, PRIMARY KEY(sha_a, sha_b));
        """)
        // Additive migrations: an older catalog must keep working, so every column
        // added after v1 is applied here and failures are ignored when it already
        // exists. Never rewrite or drop — the catalog is the product.
        for sql in [
            "ALTER TABLE file ADD COLUMN thumb BLOB;",
            "ALTER TABLE file ADD COLUMN duration REAL;",
            "ALTER TABLE file ADD COLUMN frames BLOB;",
            "ALTER TABLE file ADD COLUMN ev REAL;",
            "ALTER TABLE file ADD COLUMN utc_instant REAL;",
            "ALTER TABLE file ADD COLUMN utc_source TEXT;",
            "ALTER TABLE file ADD COLUMN sidecar TEXT;",
            "ALTER TABLE file ADD COLUMN sidecar_rule TEXT;",
            "ALTER TABLE file ADD COLUMN sc_lat REAL;",
            "ALTER TABLE file ADD COLUMN sc_lon REAL;",
            "ALTER TABLE file ADD COLUMN name_local TEXT;",
            "ALTER TABLE file ADD COLUMN name_utc REAL;",
            "ALTER TABLE file ADD COLUMN name_rule TEXT;",
            "ALTER TABLE file ADD COLUMN album TEXT;",
            "ALTER TABLE file ADD COLUMN folder_year INTEGER;",
            "ALTER TABLE file ADD COLUMN title TEXT;",
            "ALTER TABLE file ADD COLUMN content_id TEXT;",
            "ALTER TABLE source ADD COLUMN exclude TEXT;",
            "ALTER TABLE file ADD COLUMN motion TEXT;",
            "ALTER TABLE manual_fact ADD COLUMN confirmed INTEGER NOT NULL DEFAULT 0;",
            "CREATE INDEX IF NOT EXISTS file_content ON file(content_id);",
            """
            CREATE TABLE IF NOT EXISTS zone_pick(
                day INTEGER PRIMARY KEY, utc_offset TEXT NOT NULL, chosen_at REAL NOT NULL);
            """,
            "CREATE TABLE IF NOT EXISTS setting(key TEXT PRIMARY KEY, value TEXT NOT NULL);",
            "CREATE TABLE IF NOT EXISTS keeper(sha TEXT PRIMARY KEY, chosen_at REAL NOT NULL);",
            "CREATE TABLE IF NOT EXISTS trashed(file_id INTEGER PRIMARY KEY, sha TEXT, original TEXT NOT NULL, trash_path TEXT NOT NULL, at REAL NOT NULL);",
            "CREATE TABLE IF NOT EXISTS manual_fact(sha TEXT PRIMARY KEY, day TEXT, lat REAL, lon REAL, set_at REAL NOT NULL);",
            """
            CREATE TABLE IF NOT EXISTS place_rule(
            id INTEGER PRIMARY KEY, folder TEXT, day_from INTEGER, day_to INTEGER,
            lat REAL NOT NULL, lon REAL NOT NULL, label TEXT NOT NULL, created REAL NOT NULL);
            """,
            "CREATE TABLE IF NOT EXISTS zone_fix(sha TEXT PRIMARY KEY, utc_offset TEXT NOT NULL, chosen_at REAL NOT NULL);",
            """
            CREATE TABLE IF NOT EXISTS output(
            file_id INTEGER PRIMARY KEY, cluster_id INTEGER NOT NULL, role TEXT NOT NULL,
            source TEXT NOT NULL, target TEXT NOT NULL, root TEXT NOT NULL,
            state TEXT NOT NULL, written_sha TEXT, error TEXT, verified_at REAL);
            """,
            """
            CREATE TABLE IF NOT EXISTS pair(
                a INTEGER NOT NULL, b INTEGER NOT NULL, distance INTEGER NOT NULL,
                outcome TEXT NOT NULL, mae_hi REAL, mae_lo REAL, PRIMARY KEY(a, b));
            CREATE TABLE IF NOT EXISTS pair_decision(
                sha_a TEXT NOT NULL, sha_b TEXT NOT NULL, same INTEGER NOT NULL,
                decided_at REAL NOT NULL, PRIMARY KEY(sha_a, sha_b));
            """,
        ] { try? run(sql) }
    }

    /// True when the schema has the column — lets callers degrade instead of crashing.
    func hasColumn(_ table: String, _ column: String) -> Bool {
        guard let st = try? prepare("PRAGMA table_info(\(table));") else { return false }
        defer { st.finalize() }
        while st.step() { if st.text(1) == column { return true } }
        return false
    }

    // MARK: primitives

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func run(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw Err.sql(m)
        }
    }

    /// Serialised writes — SQLite WAL allows one writer.
    func write<T>(_ body: () throws -> T) rethrows -> T { try queue.sync(execute: body) }

    func transaction(_ body: () throws -> Void) throws {
        try write {
            try run("BEGIN IMMEDIATE;")
            do { try body(); try run("COMMIT;") }
            catch { try? run("ROLLBACK;"); throw error }
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw Err.sql(String(cString: sqlite3_errmsg(db)))
        }
        return Statement(s)
    }

    func setting(_ key: String) -> String? {
        guard let st = try? prepare("SELECT value FROM setting WHERE key = ?;") else { return nil }
        defer { st.finalize() }
        st.bind(1, key)
        return st.step() ? st.text(0) : nil
    }

    func setSetting(_ key: String, _ value: String) {
        try? transaction {
            let st = try prepare("INSERT OR REPLACE INTO setting(key, value) VALUES(?,?);")
            st.bind(1, key).bind(2, value).done(); st.finalize()
        }
    }

    var lastInsertRowID: Int { Int(sqlite3_last_insert_rowid(db)) }

    func scalarInt(_ sql: String) -> Int {
        guard let st = try? prepare(sql) else { return 0 }
        defer { st.finalize() }
        return st.step() ? st.int(0) : 0
    }
}

/// Everything a person has decided, as it stood at one moment — for undo.
///
/// The decision tables are small (a row per choice, not per photograph), so a
/// snapshot is cheap, and one mechanism makes every choice in the app undoable:
/// take a snapshot, act; undo restores it. Derived tables — groups, resolutions —
/// are never snapshotted: they are rebuilt from the decisions.
struct Snapshot {
    static let tables = ["zone_pick", "pair_decision", "keeper", "zone_fix", "manual_fact", "place_rule", "setting"]
    fileprivate var rows: [String: [String]] = [:]     // table -> INSERT statements
    fileprivate var excludes: [String] = []             // UPDATE statements for source.exclude

    static func take(_ c: Catalog) -> Snapshot {
        var snap = Snapshot()
        for t in tables {
            var cols: [String] = []
            if let st = try? c.prepare("PRAGMA table_info(\(t));") {
                while st.step() { if let n = st.text(1) { cols.append(n) } }
                st.finalize()
            }
            guard !cols.isEmpty else { continue }
            let values = cols.map { "quote(\($0))" }.joined(separator: " || ',' || ")
            var ins: [String] = []
            if let st = try? c.prepare("SELECT 'INSERT INTO \(t)(\(cols.joined(separator: ","))) VALUES(' || \(values) || ');' FROM \(t);") {
                while st.step() { if let q = st.text(0) { ins.append(q) } }
                st.finalize()
            }
            snap.rows[t] = ins
        }
        if let st = try? c.prepare("SELECT 'UPDATE source SET exclude = ' || quote(exclude) || ' WHERE id = ' || id || ';' FROM source;") {
            while st.step() { if let q = st.text(0) { snap.excludes.append(q) } }
            st.finalize()
        }
        return snap
    }

    func apply(_ c: Catalog) {
        try? c.transaction {
            for (t, ins) in rows {
                try c.run("DELETE FROM \(t);")
                for q in ins { try c.run(q) }
            }
            for q in excludes { try c.run(q) }
        }
    }
}

/// Thin wrapper so call sites read like SQL, not like C.
final class Statement {
    private let s: OpaquePointer
    init(_ s: OpaquePointer) { self.s = s }
    func finalize() { sqlite3_finalize(s) }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @discardableResult func bind(_ i: Int32, _ v: String?) -> Statement {
        if let v { sqlite3_bind_text(s, i, v, -1, Statement.transient) }
        else { sqlite3_bind_null(s, i) }
        return self
    }
    @discardableResult func bind(_ i: Int32, _ v: Int?) -> Statement {
        if let v { sqlite3_bind_int64(s, i, Int64(v)) } else { sqlite3_bind_null(s, i) }
        return self
    }
    @discardableResult func bind(_ i: Int32, _ v: Double?) -> Statement {
        if let v { sqlite3_bind_double(s, i, v) } else { sqlite3_bind_null(s, i) }
        return self
    }
    @discardableResult func bind(_ i: Int32, _ v: Data?) -> Statement {
        if let v, !v.isEmpty {
            _ = v.withUnsafeBytes { sqlite3_bind_blob(s, i, $0.baseAddress, Int32(v.count), Statement.transient) }
        } else { sqlite3_bind_null(s, i) }
        return self
    }
    func blob(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(s, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
    }
    @discardableResult func bind(_ i: Int32, _ v: UInt64?) -> Statement {
        if let v { sqlite3_bind_int64(s, i, Int64(bitPattern: v)) } else { sqlite3_bind_null(s, i) }
        return self
    }

    func step() -> Bool { sqlite3_step(s) == SQLITE_ROW }
    @discardableResult func done() -> Bool { sqlite3_step(s) == SQLITE_DONE }
    func reset() { sqlite3_reset(s); sqlite3_clear_bindings(s) }

    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }
    func uint64(_ i: Int32) -> UInt64 { UInt64(bitPattern: sqlite3_column_int64(s, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(s, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(s, i) == SQLITE_NULL }
    func text(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }
}
