import Foundation

/// Stages 1 and 2 — find files, then read them — shared by the app and the tests.
///
/// Both are **resumable**: every batch of results is committed as it is produced,
/// so quitting halfway through a library loses at most one batch per worker, and
/// the next run picks up exactly where this one stopped. Before this, extraction
/// held every result in memory and wrote once at the end — an interrupted run of
/// a large library lost all of it.
enum Ingest {

    /// Checked from worker threads, where `Task.isCancelled` cannot see the task.
    final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    // MARK: exclusions

    /// What a person asked to leave out of a source, one pattern per line. A plain
    /// word is a folder or file name ("Screenshots", "WhatsApp Images"); a pattern
    /// with `*` or `?` is matched against the file name and the relative path
    /// ("*.png", "*/Thumbnails/*"). Case never matters.
    struct Exclusions {
        let names: Set<String>
        let globs: [String]
        init(_ text: String?) {
            let lines = (text ?? "").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            names = Set(lines.filter { !$0.contains("*") && !$0.contains("?") && !$0.contains("/") })
            globs = lines.filter { $0.contains("*") || $0.contains("?") || $0.contains("/") }
        }
        var isEmpty: Bool { names.isEmpty && globs.isEmpty }
        /// True for a directory name that removes the whole subtree.
        func excludesFolder(_ name: String) -> Bool { names.contains(name.lowercased()) }
        func excludes(rel: String) -> Bool {
            let r = rel.lowercased()
            let parts = r.split(separator: "/").map(String.init)
            if parts.contains(where: names.contains) { return true }
            let file = parts.last ?? r
            return globs.contains { fnmatch($0, file, 0) == 0 || fnmatch($0, r, 0) == 0 }
        }
    }

    // MARK: scan

    struct ScanReport {
        var seen = 0, added = 0, changed = 0, removed = 0, excluded = 0
        /// Sources whose folder is missing — an unplugged drive. Their files are
        /// left exactly as they were: an absent folder is not an empty one.
        var unavailable: [String] = []
        /// Sources macOS would not let the app read: a folder it was denied access to.
        var denied: [String] = []
        /// Files that are not a photo or video the app can read — camcorder AVIs,
        /// documents, unknown RAW containers — counted so nobody mistakes "all read"
        /// for "all seen" (review finding 5).
        var unrecognised = 0
    }

    static func scan(_ c: Catalog, limit: Int? = nil, stop: Stop = Stop(),
                     progress: (Int) -> Void = { _ in }) -> ScanReport {
        var r = ScanReport()
        var roots: [(Int, String, Exclusions)] = []
        if let st = try? c.prepare("SELECT id, path, exclude FROM source ORDER BY id;") {
            while st.step() { roots.append((st.int(0), st.text(1) ?? "", Exclusions(st.text(2)))) }
            st.finalize()
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        for (sid, root, ex) in roots {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
                r.unavailable.append(root); continue
            }
            guard FileManager.default.isReadableFile(atPath: root),
                  (try? FileManager.default.contentsOfDirectory(atPath: root)) != nil else {
                r.denied.append(root); continue
            }
            var skipped: [String: Int] = [:]      // by extension, for the source's own record
            // what the catalog already knows about this source
            var known: [String: (size: Int, mtime: Double)] = [:]
            if let st = try? c.prepare("SELECT path, size, mtime FROM file WHERE source_id = ?;") {
                st.bind(1, sid)
                while st.step() { known[st.text(0) ?? ""] = (st.int(1), st.double(2)) }
                st.finalize()
            }
            var seen = Set<String>()
            var fresh: [(String, String, Int, Double, Sniff.Result)] = []
            var touched: [(String, Int, Double)] = []
            var complete = true

            func flush() {
                try? c.transaction {
                    let ins = try c.prepare("""
                        INSERT OR IGNORE INTO file(source_id, path, rel_path, size, mtime, kind, mime, ext)
                        VALUES(?,?,?,?,?,?,?,?);
                        """)
                    for f in fresh {
                        ins.bind(1, sid).bind(2, f.0).bind(3, f.1).bind(4, f.2).bind(5, f.3)
                           .bind(6, f.4.kind.rawValue).bind(7, f.4.mime)
                           .bind(8, (f.0 as NSString).pathExtension.lowercased())
                        ins.done(); ins.reset()
                    }
                    ins.finalize()
                    // a file that changed since it was read is read again
                    let up = try c.prepare("UPDATE file SET size=?, mtime=?, state='scanned' WHERE path=?;")
                    for t in touched { up.bind(1, t.1).bind(2, t.2).bind(3, t.0).done(); up.reset() }
                    up.finalize()
                }
                fresh.removeAll(); touched.removeAll()
            }

            let base = URL(fileURLWithPath: root)
            // The enumerator reports resolved paths, so a source reached through a
            // symlink (/tmp, /var, an alias folder) must be compared resolved too —
            // otherwise every relative path collapses to a bare filename and the
            // folders a file sits in are lost. realpath(3), not Foundation's
            // resolvingSymlinksInPath(), which deliberately strips "/private" and so
            // disagrees with the enumerator in exactly this case.
            let resolvedRoot: String = {
                guard let r = realpath(root, nil) else { return root }
                defer { free(r) }
                return String(cString: r)
            }()
            if let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) {
                for case let u as URL in e {
                    if stop.isSet { complete = false; break }
                    if let limit, r.seen >= limit { complete = false; break }
                    let rv = try? u.resourceValues(forKeys: Set(keys))
                    guard rv?.isRegularFile == true else {
                        // an excluded folder is not walked at all
                        if !ex.isEmpty, ex.excludesFolder(u.lastPathComponent) { e.skipDescendants() }
                        // Another Photos library inside a source is a package, not a folder
                        // of photographs: its derivatives are thumbnails of its originals,
                        // and would show up as duplicates of them (review finding 11).
                        // A source that *is* an originals folder is walked as before.
                        if u.pathExtension == "photoslibrary", !resolvedRoot.hasPrefix(u.path + "/") { e.skipDescendants() }
                        continue
                    }
                    let path = u.path
                    if !ex.isEmpty {
                        let relPath = path.hasPrefix(resolvedRoot + "/") ? String(path.dropFirst(resolvedRoot.count + 1))
                            : path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : u.lastPathComponent
                        // an excluded file is simply not seen, so a finished walk forgets it
                        if ex.excludes(rel: relPath) { r.excluded += 1; continue }
                    }
                    let size = rv?.fileSize ?? 0
                    let mtime = rv?.contentModificationDate?.timeIntervalSince1970 ?? 0
                    if let k = known[path] {
                        seen.insert(path); r.seen += 1
                        if k.size != size || abs(k.mtime - mtime) > 0.5 {
                            touched.append((path, size, mtime)); r.changed += 1
                        }
                    } else {
                        guard let kind = Sniff.sniff(u) else {              // magic bytes, not extension
                            let ext = u.pathExtension.lowercased()
                            skipped[ext.isEmpty ? "(no extension)" : ext, default: 0] += 1
                            r.unrecognised += 1
                            continue
                        }
                        seen.insert(path); r.seen += 1; r.added += 1
                        let rel = path.hasPrefix(resolvedRoot + "/") ? String(path.dropFirst(resolvedRoot.count + 1))
                                : path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1))
                                : u.lastPathComponent
                        fresh.append((path, rel, size, mtime, kind))
                    }
                    if fresh.count + touched.count >= 500 { flush(); progress(r.seen) }
                }
            }
            flush(); progress(r.seen)

            // Only a walk that finished may conclude a file is gone, or say what it skipped.
            if complete {
                let kinds = skipped.sorted { $0.value > $1.value }.prefix(8)
                    .map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
                try? c.transaction {
                    let st = try c.prepare("UPDATE source SET unrecognised = ?, unrecognised_kinds = ? WHERE id = ?;")
                    st.bind(1, skipped.values.reduce(0, +)).bind(2, kinds.isEmpty ? nil : kinds).bind(3, sid).done(); st.finalize()
                }
                let gone = known.keys.filter { !seen.contains($0) }
                if !gone.isEmpty {
                    try? c.transaction {
                        let del = try c.prepare("DELETE FROM file WHERE path = ?;")
                        for g in gone { del.bind(1, g).done(); del.reset() }
                        del.finalize()
                    }
                    r.removed += gone.count
                }
            }
        }
        return r
    }

    // MARK: extract

    struct ExtractReport { var total = 0, done = 0, failed = 0, stopped = false }

    /// Read every file not yet read, committing as it goes. A file that cannot be
    /// read is marked `failed` rather than retried forever; it is read again only
    /// if it changes on disk.
    static func extract(_ c: Catalog, workers: Int, batch: Int = 200, stop: Stop = Stop(),
                        progress: @escaping (Int, Int) -> Void = { _, _ in }) -> ExtractReport {
        var pending: [(id: Int, path: String, rel: String, isImage: Bool)] = []
        if let st = try? c.prepare("SELECT id, path, rel_path, kind FROM file WHERE state='scanned' ORDER BY id;") {
            while st.step() { pending.append((st.int(0), st.text(1) ?? "", st.text(2) ?? "", st.text(3) == "image")) }
            st.finalize()
        }
        let index = Sidecar.Index()
        var r = ExtractReport(total: pending.count)
        guard !pending.isEmpty else { return r }
        let lock = NSLock()
        let n = max(1, workers)

        DispatchQueue.concurrentPerform(iterations: n) { slot in
            var ok: [(Int, Facts, Outside)] = []
            var bad: [Int] = []
            func commit() {
                guard !ok.isEmpty || !bad.isEmpty else { return }
                write(c, ok, failed: bad)
                lock.lock(); r.done += ok.count; r.failed += bad.count
                let (d, t) = (r.done + r.failed, r.total); lock.unlock()
                ok.removeAll(); bad.removeAll()
                progress(d, t)
            }
            var i = slot
            while i < pending.count {
                if stop.isSet { break }
                let p = pending[i]
                if let f = Extractor.extract(URL(fileURLWithPath: p.path), isImage: p.isImage) {
                    ok.append((p.id, f, outside(p.path, rel: p.rel, index)))
                } else {
                    bad.append(p.id)
                }
                if ok.count + bad.count >= batch { commit() }
                i += n
            }
            commit()
        }
        r.stopped = stop.isSet
        return r
    }

    /// What a file's surroundings say about it: its Takeout sidecar, its name, and
    /// the folders it sits in. Recorded beside what the file itself says, never
    /// merged into it, so the resolver can rank them and the UI can show which won.
    struct Outside {
        var sidecar: String?, sidecarRule: String?
        var sc: Sidecar.Facts?
        var name: Names.Claim?
        var album: String?, folderYear: Int?
    }

    static func outside(_ path: String, rel: String, _ index: Sidecar.Index) -> Outside {
        var o = Outside()
        if let (sp, rule) = Sidecar.find(path, index),
           let d = FileManager.default.contents(atPath: sp) {
            o.sidecar = sp; o.sidecarRule = rule; o.sc = Sidecar.parse(d)
        }
        // the name before export, when Takeout renamed the file
        o.name = Names.claim((path as NSString).lastPathComponent)
            ?? o.sc?.title.flatMap(Names.claim)
        (o.folderYear, o.album) = Names.folder(rel)
        return o
    }

    static func write(_ c: Catalog, _ rows: [(Int, Facts, Outside)], failed: [Int] = []) {
        try? c.transaction {
            let st = try c.prepare("""
                UPDATE file SET sha256=?, pixel_hash=?, dhash64=?, width=?, height=?,
                    captured_at=?, utc_offset=?, lat=?, lon=?, make=?, model=?,
                    thumb=?, duration=?, frames=?, ev=?,
                    utc_instant=?, utc_source=?, sidecar=?, sidecar_rule=?, sc_lat=?, sc_lon=?,
                    name_local=?, name_utc=?, name_rule=?, album=?, folder_year=?, title=?,
                    content_id=?, motion=?, state='extracted'
                WHERE id=?;
                """)
            for (id, f, o) in rows {
                // the most direct instant: the container's, else the sidecar's
                let (u, us): (Double?, String?) = f.utcInstant != nil ? (f.utcInstant, "video container")
                    : o.sc?.takenUTC != nil ? (o.sc?.takenUTC, "Takeout sidecar") : (nil, nil)
                var nl: String? = nil, nu: Double? = nil, nr: String? = nil
                switch o.name {
                case .wall(let t, let r): nl = t; nr = r
                case .utc(let t, let r): nu = t; nr = r
                case nil: break
                }
                st.bind(1, f.sha256).bind(2, f.pixelHash).bind(3, f.dhash64)
                  .bind(4, f.width).bind(5, f.height)
                  .bind(6, f.capturedAt).bind(7, f.utcOffset)
                  .bind(8, f.lat).bind(9, f.lon)
                  .bind(10, f.make).bind(11, f.model).bind(12, f.thumb)
                  .bind(13, f.duration).bind(14, f.frames).bind(15, f.ev)
                  .bind(16, u).bind(17, us).bind(18, o.sidecar).bind(19, o.sidecarRule)
                  .bind(20, o.sc?.lat).bind(21, o.sc?.lon)
                  .bind(22, nl).bind(23, nu).bind(24, nr).bind(25, o.album).bind(26, o.folderYear)
                  .bind(27, o.sc?.title).bind(28, f.contentID).bind(29, f.motion).bind(30, id)
                st.done(); st.reset()
            }
            st.finalize()
            let fs = try c.prepare("UPDATE file SET state='failed' WHERE id=?;")
            for id in failed { fs.bind(1, id).done(); fs.reset() }
            fs.finalize()
        }
    }

    /// Performance cores — measured: 10 beats 14 on this hardware (SPIKES §3).
    static let workers: Int = {
        var n: Int32 = 0; var sz = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &n, &sz, nil, 0) == 0, n > 0 { return Int(n) }
        return max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
    }()
}
