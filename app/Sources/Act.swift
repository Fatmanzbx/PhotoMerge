import Foundation

/// Write a clean, merged copy of the library (ROADMAP v1.1). The originals are
/// never touched; the output is a new tree:
///
///     YYYY/MM/YYYYMMDD_HHMMSS.ext        one file per photograph, the kept copy
///     YYYY/MM/YYYYMMDD_HHMMSS_2.ext      a second photograph in the same second
///     YYYY/MM/YYYYMMDD_HHMMSS.mov        a Live Photo's clip, beside its still
///     Undated/<original name>            nothing to date it by
///
/// Safety, from PLAN §9:
///  - every file is written under a temporary name, **verified**, and only then
///    renamed into place; a rename never overwrites anything;
///  - verification re-reads the written file and requires the *same decoded
///    pixels* as the source (for a video: the same duration and sampled frames) —
///    the same definition of identity the grouping itself used;
///  - the manifest (`output`) is written as it goes, so a crash leaves a state
///    that can be resumed or undone, and undo deletes only files that are still
///    byte-for-byte what was written.
enum Act {

    // MARK: options

    struct Options: Equatable, Codable {
        /// Write worked-out places into files that have none. Measured places are
        /// already in the file and are never overwritten.
        var writePlaces = true
        /// Write worked-out timezones. A zone read from the file is always written.
        var writeInferredZones = true
    }

    // MARK: plan

    struct Item: Equatable {
        let clusterID: Int
        let fileID: Int
        let role: String            // canonical | companion
        let source: String
        let target: String          // relative to the output root
    }

    /// Choose a target for every kept copy and companion. Deterministic: the same
    /// catalog always plans the same tree.
    static func plan(_ c: Catalog) -> [Item] {
        struct Row { let cid: Int; let fid: Int; let role: String; let path: String; let mime: String?
                     let local: String?; let timeSource: String }
        var rows: [Row] = []
        if let st = try? c.prepare("""
            SELECT m.cluster_id, f.id, m.role, f.path, f.mime, r.local_time, COALESCE(r.time_source,'none')
            FROM member m JOIN file f ON f.id = m.file_id
            LEFT JOIN resolution r ON r.cluster_id = m.cluster_id
            WHERE m.role IN ('canonical','companion')
            ORDER BY r.local_time, m.cluster_id, CASE m.role WHEN 'canonical' THEN 0 ELSE 1 END;
            """) {
            while st.step() {
                rows.append(Row(cid: st.int(0), fid: st.int(1), role: st.text(2) ?? "", path: st.text(3) ?? "",
                                mime: st.text(4), local: st.text(5), timeSource: st.text(6) ?? "none"))
            }
            st.finalize()
        }
        var used = Set<String>()               // lowercased: APFS is usually case-insensitive
        var stemOf: [Int: String] = [:]        // a clip shares its still's stem
        var out: [Item] = []
        for r in rows {
            let ext = outputExtension(r.path, mime: r.mime)
            var stem: String
            if let s = stemOf[r.cid] {
                stem = s
            } else {
                stem = baseStem(r.local, timeSource: r.timeSource, original: r.path)
                var n = 1, candidate = stem
                // a stem is taken if any file already uses it, whatever its extension
                while used.contains(candidate.lowercased()) { n += 1; candidate = "\(stem)_\(n)" }
                stem = candidate
                used.insert(stem.lowercased())
                stemOf[r.cid] = stem
            }
            out.append(Item(clusterID: r.cid, fileID: r.fid, role: r.role, source: r.path, target: stem + "." + ext))
        }
        return out
    }

    static func baseStem(_ local: String?, timeSource: String, original: String) -> String {
        // A file date is when a file was copied, not when it was taken; a name built
        // from it would look like a capture time. Such files keep their own names.
        guard let t = local, let p = Resolver.parse(t), !timeSource.hasPrefix("mtime") else {
            let name = ((original as NSString).lastPathComponent as NSString).deletingPathExtension
            return "Undated/" + name
        }
        // a time shown in UTC for want of a zone says so in its name
        let z = timeSource.hasSuffix("shown in UTC") ? "Z" : ""
        return String(format: "%04d/%02d/%04d%02d%02d_%02d%02d%02d%@", p.y, p.mo, p.y, p.mo, p.d, p.h, p.mi, p.sec, z)
    }

    /// The file's real type decides, not its name: an HEIC called `.jpg` is written
    /// as `.heic`. A matching original extension is kept, lowercased.
    static func outputExtension(_ path: String, mime: String?) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let families: [String: [String]] = [
            "image/jpeg": ["jpg", "jpeg"], "image/heic": ["heic", "heif"], "image/png": ["png"],
            "image/gif": ["gif"], "image/tiff": ["tif", "tiff", "dng"], "image/webp": ["webp"],
            "video/mp4": ["mov", "mp4", "m4v", "3gp"],
        ]
        guard let mime, let fam = families[mime] else { return ext.isEmpty ? "bin" : ext }
        return fam.contains(ext) ? ext : fam[0] == "mov" ? "mp4" : fam[0]
    }

    // MARK: tags

    /// The metadata to write for one file: the full capture-date set, so that no
    /// reader finds a stale date that outranks EXIF (ROADMAP v1.1), and a place
    /// where the file has none. `ModifyDate` is left alone — it means last modified.
    static func tags(isVideo: Bool, local: String?, offset: String?, zoneSource: String,
                     timeSource: String, lat: Double?, lon: Double?, placeSource: String,
                     fileHasGPS: Bool, options: Options) -> [String: String] {
        var t: [String: String] = [:]
        // A clock shown in UTC for want of a zone is not a local time: write no date.
        if let local, !timeSource.hasSuffix("shown in UTC"), !timeSource.hasPrefix("mtime") {
            let zoneRead = zoneSource == "tag" || zoneSource.hasPrefix("clock + ")
                || zoneSource == "you chose it" || zoneSource == "you corrected it"
            let off = (offset != nil && (zoneRead || options.writeInferredZones)) ? offset : nil
            let (d, h) = (String(local.prefix(10)), String(local.suffix(8)))
            if isVideo {
                if let off {
                    // QuickTime dates are UTC; with the offset given, exiftool converts.
                    t["QuickTime:CreateDate"] = local + off
                    t["QuickTime:MediaCreateDate"] = local + off
                    t["Keys:CreationDate"] = local + off
                }
            } else {
                t["EXIF:DateTimeOriginal"] = local
                t["EXIF:CreateDate"] = local
                t["XMP-xmp:CreateDate"] = local + (off ?? "")
                t["XMP-photoshop:DateCreated"] = local + (off ?? "")
                t["IPTC:DateCreated"] = d
                t["IPTC:TimeCreated"] = h + (off ?? "")
                if let off {
                    t["EXIF:OffsetTimeOriginal"] = off
                    t["EXIF:OffsetTimeDigitized"] = off
                }
            }
        }
        if let lat, let lon, !fileHasGPS, placeSource != "none",
           options.writePlaces || placeSource == "measured" || placeSource == "sidecar GPS"
                || placeSource.hasPrefix("your rule: ") || placeSource == "you entered it" || placeSource == "you confirmed it" {
            if isVideo {
                t["Keys:GPSCoordinates"] = String(format: "%.6f, %.6f, 0", lat, lon)
            } else {
                t["EXIF:GPSLatitude"] = String(format: "%.7f", abs(lat))
                t["EXIF:GPSLatitudeRef"] = lat >= 0 ? "N" : "S"
                t["EXIF:GPSLongitude"] = String(format: "%.7f", abs(lon))
                t["EXIF:GPSLongitudeRef"] = lon >= 0 ? "E" : "W"
            }
        }
        return t
    }

    // MARK: run

    enum Refusal: Error, CustomStringConvertible {
        case insideSource(String), containsSource(String), noWriter, noSpace(need: Int, free: Int)
        var description: String {
            switch self {
            case .noSpace(let need, let free):
                return "Not enough space: this needs about \(byteString(need)) and the destination has "
                     + "\(byteString(free)) free. Choose a larger drive; nothing has been written."
            case .insideSource(let s): return "The destination is inside a source (\(s)). The copy would be read back as more photographs."
            case .containsSource(let s): return "A source (\(s)) is inside the destination. Choose an empty folder elsewhere."
            case .noWriter: return "exiftool is missing, so dates and places cannot be written losslessly."
            }
        }
    }

    struct Report { var planned = 0, written = 0, alreadyDone = 0, failed = 0, stopped = false
                    var failures: [(String, String)] = [] }

    static let partialMarker = ".photomerge-partial"

    /// `20210414_080000.photomerge-partial.mov`: the real extension stays last,
    /// because AVFoundation identifies a container by it — with the marker at the
    /// end it could not open the written video to verify it, and every one failed.
    static func partialPath(_ final: String) -> String {
        let ext = (final as NSString).pathExtension
        return (final as NSString).deletingPathExtension + partialMarker + (ext.isEmpty ? "" : "." + ext)
    }

    /// The destination may be neither inside a source nor contain one.
    static func check(_ c: Catalog, root: String) throws {
        let r = URL(fileURLWithPath: root).standardizedFileURL.path + "/"
        if let st = try? c.prepare("SELECT path FROM source;") {
            defer { st.finalize() }
            while st.step() {
                let s = URL(fileURLWithPath: st.text(0) ?? "").standardizedFileURL.path + "/"
                if r.hasPrefix(s) { throw Refusal.insideSource(s) }
                if s.hasPrefix(r) { throw Refusal.containsSource(s) }
            }
        }
    }

    /// Space still needed at the destination, and space free there. Every file
    /// gets new metadata, so exiftool writes each one in full: an APFS clone saves
    /// nothing once a file is rewritten. A 2% margin plus 1 GB for the volume itself.
    static func space(_ c: Catalog, root: String) -> (need: Int, free: Int) {
        let r = root.replacingOccurrences(of: "'", with: "''")
        let remaining = c.scalarInt("""
            SELECT COALESCE(SUM(f.size),0) FROM member m JOIN file f ON f.id = m.file_id
            WHERE m.role IN ('canonical','companion')
              AND f.id NOT IN (SELECT file_id FROM output WHERE state='verified' AND root='\(r)');
            """)
        var probe = URL(fileURLWithPath: root)
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" { probe.deleteLastPathComponent() }
        // The smaller of "free now" and "free if macOS purges what it can": a long
        // write should not depend on the system reclaiming space in time.
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                    .volumeAvailableCapacityKey])
        let important = v?.volumeAvailableCapacityForImportantUsage.map(Int.init) ?? Int.max
        let now = v?.volumeAvailableCapacity ?? Int.max
        let free = min(important, now)
        return (remaining > 0 ? remaining + remaining / 50 + 1_000_000_000 : 0, free)
    }

    /// Plan (or re-plan) into the manifest: verified rows stand; everything else is
    /// replaced by the current plan, so a regroup since the last run is honoured.
    /// First, finish what a crash interrupted: a file moved into place but not yet
    /// recorded is recognised by its hash, and half-written files are swept away.
    static func prepare(_ c: Catalog, root: String) {
        reconcile(c, root: root)
        let items = plan(c)
        try? c.transaction {
            try c.run("DELETE FROM output WHERE state != 'verified' OR root != '\(root.replacingOccurrences(of: "'", with: "''"))';")
            let st = try c.prepare("""
                INSERT OR IGNORE INTO output(file_id, cluster_id, role, source, target, root, state)
                VALUES(?,?,?,?,?,?,'planned');
                """)
            for i in items {
                st.bind(1, i.fileID).bind(2, i.clusterID).bind(3, i.role).bind(4, i.source)
                  .bind(5, i.target).bind(6, root).done(); st.reset()
            }
            st.finalize()
        }
    }

    /// A row is marked `committing`, with its final name and hash, before its file is
    /// moved into place. After a crash, such a row whose file is there and matches is
    /// verified; otherwise it is replanned. Without this, a file moved in just before a
    /// crash was written again beside itself as `_2`, and Undo never knew the first.
    static func reconcile(_ c: Catalog, root: String) {
        var rows: [(Int, String, String?)] = []
        if let st = try? c.prepare("SELECT file_id, target, written_sha FROM output WHERE root = ? AND state = 'committing';") {
            st.bind(1, root)
            while st.step() { rows.append((st.int(0), st.text(1) ?? "", st.text(2))) }
            st.finalize()
        }
        for (id, target, sha) in rows {
            let path = (root as NSString).appendingPathComponent(target)
            if let data = FileManager.default.contents(atPath: path), Extractor.sha(data) == sha {
                record(c, id, state: "verified", target: target, sha: sha)
            } else {
                record(c, id, state: "planned")
            }
        }
        // `.photomerge-partial` is this app's own marker: nothing else makes such a file
        if let walk = FileManager.default.enumerator(atPath: root) {
            for case let rel as String in walk where rel.contains(partialMarker) {
                try? FileManager.default.removeItem(atPath: (root as NSString).appendingPathComponent(rel))
            }
        }
    }

    /// Write everything not yet verified. Resumable: stop or crash at any point and
    /// run again; a half-written file is only ever a `.photomerge-partial`.
    static func run(_ c: Catalog, root: String, options: Options = Options(), workers: Int,
                    stop: Ingest.Stop = Ingest.Stop(),
                    progress: @escaping (Int, Int) -> Void = { _, _ in }) throws -> Report {
        try check(c, root: root)
        guard ExifTool.locate() != nil else { throw Refusal.noWriter }
        let (need, free) = space(c, root: root)
        guard need <= free else { throw Refusal.noSpace(need: need, free: free) }
        prepare(c, root: root)

        struct Job { let fileID: Int; let source: String; let target: String; let isVideo: Bool
                     let pixel: String?; let sha: String?; let frames: Data?; let duration: Double?
                     let fileHasGPS: Bool
                     let local: String?; let offset: String?; let zoneSource: String; let timeSource: String
                     let lat: Double?; let lon: Double?; let placeSource: String; let instant: Double? }
        var jobs: [Job] = []
        if let st = try? c.prepare("""
            SELECT o.file_id, o.source, o.target, f.kind, f.pixel_hash, f.sha256, f.frames, f.duration,
                   f.lat IS NOT NULL, r.local_time, r.utc_offset, COALESCE(r.zone_source,'none'),
                   COALESCE(r.time_source,'none'), r.lat, r.lon, COALESCE(r.place_source,'none'), r.instant
            FROM output o JOIN file f ON f.id = o.file_id
            LEFT JOIN resolution r ON r.cluster_id = o.cluster_id
            WHERE o.state = 'planned' ORDER BY o.target;
            """) {
            while st.step() {
                jobs.append(Job(fileID: st.int(0), source: st.text(1) ?? "", target: st.text(2) ?? "",
                                isVideo: st.text(3) == "video", pixel: st.text(4), sha: st.text(5),
                                frames: st.blob(6), duration: st.isNull(7) ? nil : st.double(7),
                                fileHasGPS: st.int(8) != 0, local: st.text(9), offset: st.text(10),
                                zoneSource: st.text(11) ?? "none", timeSource: st.text(12) ?? "none",
                                lat: st.isNull(13) ? nil : st.double(13), lon: st.isNull(14) ? nil : st.double(14),
                                placeSource: st.text(15) ?? "none", instant: st.isNull(16) ? nil : st.double(16)))
            }
            st.finalize()
        }
        var report = Report(planned: jobs.count,
                            alreadyDone: c.scalarInt("SELECT COUNT(*) FROM output WHERE state='verified';"))
        guard !jobs.isEmpty else { return report }
        let lock = NSLock()
        let fm = FileManager.default
        let n = max(1, min(workers, jobs.count))

        DispatchQueue.concurrentPerform(iterations: n) { slot in
            let et = try? ExifTool()
            var i = slot
            while i < jobs.count {
                if stop.isSet { break }
                let j = jobs[i]; i += n
                let final = (root as NSString).appendingPathComponent(j.target)
                let partial = partialPath(final)
                func fail(_ why: String) {
                    try? fm.removeItem(atPath: partial)
                    record(c, j.fileID, state: "failed", error: why)
                    lock.lock(); report.failed += 1; report.failures.append((j.source, why))
                    let d = report.written + report.failed; lock.unlock()
                    progress(d, jobs.count)
                }
                guard fm.fileExists(atPath: j.source) else { fail("the source file is gone"); continue }
                do {
                    try fm.createDirectory(atPath: (final as NSString).deletingLastPathComponent,
                                           withIntermediateDirectories: true)
                    try? fm.removeItem(atPath: partial)                 // a leftover from a crash
                    try fm.copyItem(atPath: j.source, toPath: partial)  // an APFS clone when it can be
                } catch { fail("could not copy: \(error.localizedDescription)"); continue }

                // An image that could not be decoded is copied as-is: with no pixels to
                // compare against, a written copy could not be verified.
                let decodable = j.isVideo ? (j.duration != nil) : (j.pixel != nil)
                let t = decodable ? tags(isVideo: j.isVideo, local: j.local, offset: j.offset,
                                         zoneSource: j.zoneSource, timeSource: j.timeSource,
                                         lat: j.lat, lon: j.lon, placeSource: j.placeSource,
                                         fileHasGPS: j.fileHasGPS, options: options) : [:]
                if !t.isEmpty {
                    guard let et else { fail("exiftool did not start"); continue }
                    do { try et.write(partial, t, extra: j.isVideo ? ["-api", "QuickTimeUTC=1"] : []) }
                    catch { fail("writing metadata failed: \(error)"); continue }
                }

                // verify against the same definition of identity the grouping used
                guard let back = Extractor.extract(URL(fileURLWithPath: partial), isImage: !j.isVideo) else {
                    fail("the written file cannot be read back"); continue
                }
                if t.isEmpty {
                    guard back.sha256 == j.sha else { fail("the copy differs from the original"); continue }
                } else if j.isVideo {
                    guard let d0 = j.duration, let d1 = back.duration, abs(d0 - d1) < 0.05,
                          back.frames == j.frames else { fail("the written video's frames differ"); continue }
                } else {
                    guard back.pixelHash == j.pixel else { fail("the written image's pixels differ"); continue }
                    if let want = t["EXIF:DateTimeOriginal"], back.capturedAt != want {
                        fail("the date did not take: read back \(back.capturedAt ?? "nothing")"); continue
                    }
                }
                if let instant = j.instant {
                    try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: instant)], ofItemAtPath: partial)
                }
                // commit: never overwrite; a target taken since planning takes the next suffix
                var dest = final, k = 2
                while fm.fileExists(atPath: dest) {
                    let e = (final as NSString).pathExtension
                    dest = ((final as NSString).deletingPathExtension) + "_\(k)." + e; k += 1
                }
                let rel = String(dest.dropFirst(root.count + 1))
                record(c, j.fileID, state: "committing", target: rel, sha: back.sha256)
                do { try fm.moveItem(atPath: partial, toPath: dest) }
                catch { fail("could not move into place: \(error.localizedDescription)"); continue }
                Crash.point("act.moved")
                record(c, j.fileID, state: "verified", target: rel, sha: back.sha256)
                lock.lock(); report.written += 1; let d = report.written + report.failed; lock.unlock()
                progress(d, jobs.count)
            }
        }
        report.stopped = stop.isSet
        return report
    }

    static func record(_ c: Catalog, _ fileID: Int, state: String, error: String? = nil,
                       target: String? = nil, sha: String? = nil) {
        try? c.transaction {
            let st = try c.prepare("""
                UPDATE output SET state=?, error=?, target=COALESCE(?, target), written_sha=?,
                    verified_at=CASE WHEN ?='verified' THEN ? ELSE NULL END
                WHERE file_id=?;
                """)
            st.bind(1, state).bind(2, error).bind(3, target).bind(4, sha)
              .bind(5, state).bind(6, Date().timeIntervalSince1970).bind(7, fileID).done()
            st.finalize()
        }
    }

    // MARK: undo

    struct UndoReport { var removed = 0, keptChanged = 0, missing = 0 }

    /// Remove what was written — only files that are still exactly what was written.
    /// A file changed since (edited, re-tagged) is left alone and reported. The
    /// originals are never involved.
    static func undo(_ c: Catalog, root: String) -> UndoReport {
        var r = UndoReport()
        var rows: [(Int, String, String?)] = []
        // `committing`: moved into place by a run that crashed before recording it
        if let st = try? c.prepare("SELECT file_id, target, written_sha FROM output WHERE root = ? AND state IN ('verified','committing');") {
            st.bind(1, root)
            while st.step() { rows.append((st.int(0), st.text(1) ?? "", st.text(2))) }
            st.finalize()
        }
        let fm = FileManager.default
        var dirs = Set<String>()
        for (id, target, sha) in rows {
            let path = (root as NSString).appendingPathComponent(target)
            guard fm.fileExists(atPath: path) else { r.missing += 1; forget(c, id); continue }
            guard let data = fm.contents(atPath: path), Extractor.sha(data) == sha else { r.keptChanged += 1; continue }
            try? fm.removeItem(atPath: path)
            dirs.insert((path as NSString).deletingLastPathComponent)
            r.removed += 1; forget(c, id)
        }
        try? c.transaction { let st = try c.prepare("DELETE FROM output WHERE root = ? AND state NOT IN ('verified','committing');")
                             st.bind(1, root).done(); st.finalize() }
        if let walk = fm.enumerator(atPath: root) {
            for case let rel as String in walk where rel.contains(partialMarker) {
                let p = (root as NSString).appendingPathComponent(rel)
                try? fm.removeItem(atPath: p); dirs.insert((p as NSString).deletingLastPathComponent)
            }
        }
        // tidy the folders that are now empty, deepest first; never the root itself
        for d in dirs.sorted(by: { $0.count > $1.count }) {
            var cur = d
            while cur.count > root.count, (try? fm.contentsOfDirectory(atPath: cur))?.isEmpty == true {
                try? fm.removeItem(atPath: cur); cur = (cur as NSString).deletingLastPathComponent
            }
        }
        return r
    }

    private static func forget(_ c: Catalog, _ id: Int) {
        try? c.transaction { let st = try c.prepare("DELETE FROM output WHERE file_id = ?;")
                             st.bind(1, id).done(); st.finalize() }
    }

    // MARK: summary, before anything is written

    struct Summary: Equatable {
        var photographs = 0, files = 0, clips = 0, undated = 0, inUTC = 0
        var datesFilled = 0        // a date written into a file that had none inside it
        var placesRead = 0         // a place written from a sidecar: read, not inferred
        var placesWorkedOut = 0    // a place written that was inferred
        var zonesWorkedOut = 0     // an offset written that was inferred
        var bytes = 0
        var sample: [String] = []
    }

    static func summary(_ c: Catalog, options: Options) -> Summary {
        let items = plan(c)
        var s = Summary()
        s.files = items.count
        s.clips = items.filter { $0.role == "companion" }.count
        s.photographs = s.files - s.clips
        s.undated = items.filter { $0.target.hasPrefix("Undated/") }.count
        s.inUTC = items.filter { $0.target.contains("Z.") }.count
        s.sample = Array(items.prefix(8).map(\.target))
        s.bytes = c.scalarInt("""
            SELECT COALESCE(SUM(f.size),0) FROM member m JOIN file f ON f.id = m.file_id
            WHERE m.role IN ('canonical','companion');
            """)
        let canon = "FROM member m JOIN file f ON f.id = m.file_id JOIN resolution r ON r.cluster_id = m.cluster_id WHERE m.role = 'canonical'"
        s.datesFilled = c.scalarInt("SELECT COUNT(*) \(canon) AND f.captured_at IS NULL AND r.local_time IS NOT NULL AND r.time_source NOT LIKE 'mtime%' AND r.time_source NOT LIKE '%shown in UTC';")
        s.placesRead = c.scalarInt("SELECT COUNT(*) \(canon) AND f.lat IS NULL AND r.place_source = 'sidecar GPS';")
        if options.writePlaces {
            s.placesWorkedOut = c.scalarInt("SELECT COUNT(*) \(canon) AND f.lat IS NULL AND r.lat IS NOT NULL AND r.place_source NOT IN ('measured','sidecar GPS','none');")
        }
        if options.writeInferredZones {
            s.zonesWorkedOut = c.scalarInt("SELECT COUNT(*) \(canon) AND f.utc_offset IS NULL AND r.utc_offset IS NOT NULL AND r.zone_source NOT IN ('tag','you chose it') AND r.zone_source NOT LIKE 'clock + %';")
        }
        return s
    }
}
