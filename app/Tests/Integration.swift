import Foundation

/// End-to-end run against the real catalog, without the UI. Used to test the
/// pipeline and to pre-populate the app for inspection.
enum Integration {

    static func appCatalogURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoMerge", isDirectory: true)
            .appendingPathComponent("catalog.sqlite")
    }

    static func run(folder: URL, radius: Int, catalogURL: URL, limit: Int?) throws {
        let t0 = Date()
        let c = try Catalog(url: catalogURL)
        try c.transaction {
            try c.run("DELETE FROM member; DELETE FROM cluster; DELETE FROM file; DELETE FROM source;")
        }

        // --- source
        var sid = 0
        try c.transaction {
            let st = try c.prepare("INSERT INTO source(path, added_at) VALUES(?,?);")
            st.bind(1, folder.path).bind(2, Date().timeIntervalSince1970).done()
            st.finalize()
            sid = c.lastInsertRowID
        }

        // --- scan and extract: the app's own stages
        let sr = Ingest.scan(c, limit: limit)
        let tScan = Date()
        print("  scan     \(sr.seen) files in \(fmt(t0, tScan))")
        let workers = Ingest.workers
        let er = Ingest.extract(c, workers: workers)
        let facts = Array(repeating: 0, count: er.done)
        if er.failed > 0 { print("           \(er.failed) could not be opened") }
        let tExtract = Date()
        let rate = Double(facts.count) / tExtract.timeIntervalSince(tScan)
        print("  extract  \(facts.count) files in \(fmt(tScan, tExtract))  (\(Int(rate)) files/s, \(workers) workers)")

        // --- cluster and resolve: the app's own stages, not a copy of them
        let rep = try Pipeline.cluster(c, radius: radius)
        let tCluster = Date()
        let res = try Pipeline.resolve(c)
        let rstats = res.stats
        let tResolve = Date()
        let n = max(1, res.resolved.count)
        print("  cluster  \(rep.assets) assets from \(rep.images + rep.videos) files in \(fmt(tExtract, tCluster))")
        print("           tier A \(rep.tierA) · tier B \(rep.tierB) · tier C \(rep.tierC) · tier D \(rep.tierD)")
        print("           videos \(rep.videos) → \(rep.recordings) recordings")
        print("           \(rep.duplicates) duplicates, \(bytes(rep.wasted)) recoverable")
        print("           longest chain: \(rep.longestChain)")
        print("  resolve  \(res.resolved.count) photographs in \(fmt(tCluster, tResolve))")
        print("           dated \(rstats.dated*100/n)% · zoned \(rstats.zoned*100/n)% · located \(rstats.located*100/n)%")
        print("           time: exif \(rstats.timeFromExif) · mtime \(rstats.timeFromMtime) · batch downgraded \(rstats.batchDowngraded)")
        print("           zone: tag \(rstats.zoneFromTag) · from place \(rstats.zoneFromPlace) · from neighbour \(rstats.zoneFromNeighbour) · chosen \(rstats.zoneFromYou)")
        print("           place: measured \(rstats.placeMeasured) · same-day \(rstats.placeFromDay) · nearest \(rstats.placeFromNeighbour) · declined \(rstats.declinedDaySpansTooFar)")
        print("  total    \(fmt(t0, Date()))")
    }

    /// The radius dial's effect on a folder, through the same stages the app runs.
    static func radiusSweep(folder: URL, limit: Int?) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-sweep-\(UUID().uuidString)/c.sqlite")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        let c = try Catalog(url: tmp)
        try c.transaction {
            let st = try c.prepare("INSERT INTO source(path, added_at) VALUES(?,0);")
            st.bind(1, folder.path).done(); st.finalize()
        }
        _ = Ingest.scan(c, limit: limit)
        _ = Ingest.extract(c, workers: Ingest.workers)
        let pv = Preview.radii(Pipeline.imageItems(c), [0, 1, 2, 3, 4, 5, 6, 8])
        print("radius  duplicates  merged  put-to-you  rejected  bursts  longest chain")
        for r in pv.rows {
            print(String(format: "%-7d %-11d %-7d %-11d %-9d %-7d %d", r.radius, r.duplicates,
                         r.merged, r.variants, r.rejected, r.bursts, r.longestChain))
        }
    }

    static func fmt(_ a: Date, _ b: Date) -> String {
        String(format: "%.1fs", b.timeIntervalSince(a))
    }
    static func bytes(_ n: Int) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: Int64(n))
    }
}
