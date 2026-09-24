import Foundation

/// The stages that turn a catalog of extracted facts into groups and resolutions.
///
/// Both the app's `Engine` and the headless `Integration` harness call these, and
/// nothing else writes `cluster`, `member` or `resolution`. That is the point of
/// this file: for a stretch of development the app ran its own copy of tier C —
/// no pixel verification, no burst guard, no video tier — while every test and
/// every measurement ran `Clusterer`. The tested engine and the shipped engine had
/// quietly become two different programs.
enum Pipeline {

    // MARK: cluster

    struct ClusterReport {
        var images = 0, videos = 0, recordings = 0
        var tierA = 0, tierB = 0, tierC = 0, tierD = 0
        var duplicates = 0, wasted = 0, longestChain = 1
        var livePhotos = 0
        var assets = 0
    }

    /// Every extracted still, as the cascade sees it.
    static func imageItems(_ c: Catalog) -> [Clusterer.Item] {
        var items: [Clusterer.Item] = []
        if let st = try? c.prepare("""
            SELECT id, sha256, pixel_hash, dhash64, size, width, height, thumb, captured_at
            FROM file WHERE state='extracted' AND kind='image' ORDER BY id;
            """) {
            while st.step() {
                items.append(Clusterer.Item(id: st.int(0), sha: st.text(1), pixel: st.text(2),
                                            dhash: st.isNull(3) ? nil : st.uint64(3),
                                            bytes: st.int(4), width: st.int(5), height: st.int(6),
                                            thumb: st.blob(7).map { [UInt8]($0) },
                                            capturedAt: st.text(8)))
            }
            st.finalize()
        }
        return items
    }

    static func cluster(_ c: Catalog, radius: Int) throws -> ClusterReport {
        let items = imageItems(c)
        let rep = Clusterer.cluster(items, radius: radius, decisions: decisions(c, items))

        // Videos take tier D: duration + sampled frames. A video whose duration
        // could not be read is still an asset — it just cannot be matched.
        var vids: [Clusterer.Video] = []
        var unmatchable: [(id: Int, bytes: Int)] = []
        if let st = try? c.prepare("""
            SELECT id, duration, frames, size, width, height, thumb, captured_at
            FROM file WHERE state='extracted' AND kind='video';
            """) {
            while st.step() {
                if st.isNull(1) { unmatchable.append((st.int(0), st.int(3))); continue }
                vids.append(Clusterer.Video(
                    id: st.int(0), duration: st.double(1),
                    frames: VideoExtractor.unpack(st.blob(2)),
                    bytes: st.int(3), pixels: st.int(4) * st.int(5),
                    thumb: st.blob(6).map { [UInt8]($0) }, capturedAt: st.text(7)))
            }
            st.finalize()
        }
        let vrep = Clusterer.clusterVideos(vids)

        // Live Photos: a still and its clip are one photograph (Companions).
        var meta: [Int: (cid: String?, path: String)] = [:]
        if let st = try? c.prepare("SELECT id, content_id, path FROM file WHERE state='extracted';") {
            while st.step() { meta[st.int(0)] = (st.text(1), st.text(2) ?? "") }
            st.finalize()
        }
        func side(_ g: Int, _ ids: [Int], duration: Double = 0) -> Companions.Side {
            Companions.Side(group: g, contentIDs: Set(ids.compactMap { meta[$0]?.cid }),
                            stems: Set(ids.compactMap { meta[$0].map { Companions.stem($0.path) } }),
                            duration: duration)
        }
        let stills = rep.groups.enumerated().map { g, grp in side(g, grp.members.map { items[$0].id }) }
        let movies = vrep.groups.enumerated().map { g, grp in
            side(g, grp.members.map { vids[$0].id }, duration: vids[grp.canonical].duration)
        }
        let pairs = Companions.pair(stills: stills, movies: movies)

        // A copy a person chose is kept, whatever the ranking says.
        var keep = Set<String>()
        if let st = try? c.prepare("SELECT sha FROM keeper;") {
            while st.step() { if let h = st.text(0) { keep.insert(h) } }
            st.finalize()
        }
        var sha: [Int: String] = [:]
        if !keep.isEmpty, let st = try? c.prepare("SELECT id, sha256 FROM file WHERE sha256 IS NOT NULL;") {
            while st.step() { sha[st.int(0)] = st.text(1) }
            st.finalize()
        }
        func chosen(_ id: Int) -> Bool { sha[id].map(keep.contains) ?? false }
        /// Members reordered so a chosen copy leads, and the bytes that leaves recoverable.
        /// `members` are indices into items or vids; `fileID` maps one to its file.
        func honour(_ members: [Int], fileID: (Int) -> Int,
                    _ bytes: (Int) -> Int) -> (ids: [Int], wasted: Int, byYou: Bool) {
            let isChosen = { (m: Int) in chosen(fileID(m)) }
            guard let i = members.firstIndex(where: isChosen), i != 0 else {
                return (members, members.dropFirst().reduce(0) { $0 + bytes($1) },
                        members.first.map(isChosen) ?? false)
            }
            var o = members; o.swapAt(0, i)
            return (o, o.dropFirst().reduce(0) { $0 + bytes($1) }, true)
        }
        let pairedMovies = Set(pairs.values.map(\.movie))

        try c.transaction {
            try c.run("DELETE FROM member; DELETE FROM cluster;")
            let ci = try c.prepare("INSERT INTO cluster(method, size, wasted) VALUES(?,?,?);")
            let mi = try c.prepare("INSERT INTO member(cluster_id, file_id, role, reason) VALUES(?,?,?,?);")
            func insert(_ method: String, _ wasted: Int, _ members: [(id: Int, reason: String)],
                        companions: [(id: Int, role: String, reason: String)] = []) {
                ci.bind(1, method).bind(2, members.count + companions.count).bind(3, wasted).done()
                let cid = c.lastInsertRowID
                ci.reset()
                for (n, m) in members.enumerated() {
                    mi.bind(1, cid).bind(2, m.id).bind(3, n == 0 ? "canonical" : "duplicate")
                      .bind(4, m.reason).done(); mi.reset()
                }
                for m in companions {
                    mi.bind(1, cid).bind(2, m.id).bind(3, m.role).bind(4, m.reason).done(); mi.reset()
                }
            }
            for (gi, g0) in rep.groups.enumerated() {
                var g = g0
                let h = honour(g.members, fileID: { items[$0].id }, { items[$0].bytes })
                g.members = h.ids
                var comp: [(id: Int, role: String, reason: String)] = []
                var wasted = h.wasted
                if let (mg, rule) = pairs[gi] {
                    let vg = vrep.groups[mg]
                    wasted += vg.wasted
                    // The companion is the copy whose identifier names this still;
                    // any other copy of the same recording is a duplicate of it.
                    let stillIDs = Set(g.members.compactMap { meta[items[$0].id]?.cid })
                    let ordered = vg.members.sorted { a, b in
                        let am = meta[vids[a].id]?.cid.map(stillIDs.contains) ?? false
                        let bm = meta[vids[b].id]?.cid.map(stillIDs.contains) ?? false
                        return am && !bm
                    }
                    for (n, m) in ordered.enumerated() {
                        let v = vids[m]
                        comp.append(n == 0
                            ? (v.id, "companion", String(format: "the motion of this Live Photo, %.1fs — paired by %@", v.duration, rule))
                            : (v.id, "duplicate", "duplicate: another copy of the motion clip"))
                    }
                }
                insert(g.method, wasted, g.members.enumerated().map { n, m in
                    let it = items[m]
                    return (it.id, n == 0
                        ? (h.byYou && g.members.count > 1 ? "kept: you chose this copy"
                           : "kept: \(it.width)×\(it.height), \(it.bytes / 1024) KB — most pixels in this group")
                        : "duplicate: " + describe(g.method))
                }, companions: comp)
            }
            for (gi, g0) in vrep.groups.enumerated() where !pairedMovies.contains(gi) {
                var g = g0
                let h = honour(g.members, fileID: { vids[$0].id }, { vids[$0].bytes })
                g.members = h.ids
                insert(g.method, h.wasted, g.members.enumerated().map { n, m in
                    let v = vids[m]
                    return (v.id, n == 0
                        ? (h.byYou && g.members.count > 1 ? "kept: you chose this copy"
                           : String(format: "kept: %.1fs, %d KB — most pixels in this group", v.duration, v.bytes / 1024))
                        : "duplicate: same recording — duration and all sampled frames agree")
                })
            }
            for u in unmatchable {
                insert("single", 0, [(u.id, "kept: duration unreadable, so it cannot be matched")])
            }
            ci.finalize(); mi.finalize()

            try c.run("DELETE FROM pair;")
            let pi = try c.prepare("INSERT OR REPLACE INTO pair(a, b, distance, outcome, mae_hi, mae_lo) VALUES(?,?,?,?,?,?);")
            for pr in rep.pairs {
                pi.bind(1, pr.a).bind(2, pr.b).bind(3, pr.distance).bind(4, pr.outcome.rawValue)
                  .bind(5, pr.maeHi).bind(6, pr.maeLo).done(); pi.reset()
            }
            pi.finalize()
        }

        var r = ClusterReport()
        r.images = items.count; r.videos = vids.count + unmatchable.count
        r.recordings = vrep.groups.count - pairedMovies.count + unmatchable.count
        r.livePhotos = pairs.count
        r.tierA = rep.tierA; r.tierB = rep.tierB; r.tierC = rep.tierC; r.tierD = vrep.tierD
        r.assets = rep.groups.count + vrep.groups.count - pairedMovies.count + unmatchable.count
        r.duplicates = (rep.groups + vrep.groups).reduce(0) { $0 + max(0, $1.members.count - 1) }
        r.wasted = (rep.groups + vrep.groups).reduce(0) { $0 + $1.wasted }
        r.longestChain = rep.longestChain
        return r
    }

    /// Stored verdicts, translated from content hashes to this run's file ids.
    static func decisions(_ c: Catalog, _ items: [Clusterer.Item]) -> [Clusterer.PairKey: Bool] {
        var idOf: [String: Int] = [:]
        for it in items { if let s = it.sha, idOf[s] == nil { idOf[s] = it.id } }
        var out: [Clusterer.PairKey: Bool] = [:]
        if let st = try? c.prepare("SELECT sha_a, sha_b, same FROM pair_decision;") {
            while st.step() {
                guard let a = st.text(0).flatMap({ idOf[$0] }),
                      let b = st.text(1).flatMap({ idOf[$0] }) else { continue }
                out[Clusterer.PairKey(a, b)] = st.int(2) != 0
            }
            st.finalize()
        }
        return out
    }

    /// Keep this file in whatever group it lands in; clears any other choice among
    /// `siblings`, so a group has one keeper. `nil` file clears them all.
    static func keep(_ c: Catalog, _ file: Int?, siblings: [Int]) {
        func sha(_ id: Int) -> String? {
            guard let st = try? c.prepare("SELECT sha256 FROM file WHERE id = ?;") else { return nil }
            defer { st.finalize() }
            st.bind(1, id)
            return st.step() ? st.text(0) : nil
        }
        try? c.transaction {
            let del = try c.prepare("DELETE FROM keeper WHERE sha = ?;")
            for s in siblings.compactMap(sha) { del.bind(1, s).done(); del.reset() }
            del.finalize()
            if let file, let h = sha(file) {
                let st = try c.prepare("INSERT OR REPLACE INTO keeper(sha, chosen_at) VALUES(?,?);")
                st.bind(1, h).bind(2, Date().timeIntervalSince1970).done(); st.finalize()
            }
        }
    }

    /// Record a person's verdict on two files; `nil` withdraws it.
    static func decide(_ c: Catalog, _ fileA: Int, _ fileB: Int, same: Bool?) {
        func sha(_ id: Int) -> String? {
            guard let st = try? c.prepare("SELECT sha256 FROM file WHERE id = ?;") else { return nil }
            defer { st.finalize() }
            st.bind(1, id)
            return st.step() ? st.text(0) : nil
        }
        guard let x = sha(fileA), let y = sha(fileB) else { return }
        let (a, b) = x < y ? (x, y) : (y, x)
        try? c.transaction {
            if let same {
                let st = try c.prepare("INSERT OR REPLACE INTO pair_decision(sha_a, sha_b, same, decided_at) VALUES(?,?,?,?);")
                st.bind(1, a).bind(2, b).bind(3, same ? 1 : 0).bind(4, Date().timeIntervalSince1970).done()
                st.finalize()
            } else {
                let st = try c.prepare("DELETE FROM pair_decision WHERE sha_a = ? AND sha_b = ?;")
                st.bind(1, a).bind(2, b).done(); st.finalize()
            }
        }
    }

    static func describe(_ method: String) -> String {
        switch method {
        case "chosen":     return "you said these are the same photograph"
        case "exact":      return "byte-identical"
        case "same image": return "same image content, different encoding"
        default:           return "perceptually identical, confirmed against the pixels"
        }
    }

    // MARK: resolve

    /// Every claim each cluster's files make — the resolver's only input.
    static func claims(_ c: Catalog) -> [Resolver.Input] {
        var byCluster: [Int: Resolver.Input] = [:]
        if let st = try? c.prepare("""
            SELECT m.cluster_id, f.captured_at, f.utc_offset, f.lat, f.lon, f.mtime,
                   f.ev, f.rel_path, f.model,
                   f.utc_instant, f.utc_source, f.name_local, f.name_utc, f.name_rule, f.sc_lat, f.sc_lon,
                   f.album
            FROM member m JOIN file f ON f.id = m.file_id
            ORDER BY m.cluster_id, f.id;
            """) {
            while st.step() {
                let cid = st.int(0)
                var inp = byCluster[cid] ?? Resolver.Input(clusterID: cid)
                inp.claims.append(Resolver.Claim(
                    capturedAt: st.text(1), utcOffset: st.text(2),
                    lat: st.isNull(3) ? nil : st.double(3),
                    lon: st.isNull(4) ? nil : st.double(4),
                    mtime: st.double(5),
                    ev: st.isNull(6) ? nil : st.double(6),
                    fileName: (st.text(7) as NSString?)?.lastPathComponent,
                    model: st.text(8),
                    // a container's or sidecar's instant, else one from the filename
                    utcInstant: st.isNull(9) ? (st.isNull(12) ? nil : st.double(12)) : st.double(9),
                    utcSource: st.isNull(9) ? (st.isNull(12) ? nil : st.text(13)) : st.text(10),
                    nameLocal: st.text(11), nameRule: st.text(11) != nil ? st.text(13) : nil,
                    sidecarLat: st.isNull(14) ? nil : st.double(14),
                    sidecarLon: st.isNull(15) ? nil : st.double(15),
                    album: st.text(16)))
                byCluster[cid] = inp
            }
            st.finalize()
        }
        // Sorted, so the resolver sees the same order on every run.
        return byCluster.values.sorted { $0.clusterID < $1.clusterID }
    }

    /// Corrected offsets, from content hashes to this grouping's clusters.
    static func fixes(_ c: Catalog) -> [Int: Resolver.Fix] {
        var out: [Int: Resolver.Fix] = [:]
        if let st = try? c.prepare("""
            SELECT m.cluster_id, z.utc_offset, z.keep_clock FROM zone_fix z
            JOIN file f ON f.sha256 = z.sha JOIN member m ON m.file_id = f.id;
            """) {
            while st.step() { if let o = st.text(1) { out[st.int(0)] = Resolver.Fix(offset: o, keepClock: st.int(2) != 0) } }
            st.finalize()
        }
        return out
    }

    /// Correct these clusters' offsets, or withdraw with nil. By default the instant
    /// stands and the clock moves (a correct moment stored under the wrong zone);
    /// with `keepClock` the clock stands and the instant moves (a camera on local time
    /// whose import stamped a home offset) — review finding 13.
    static func fix(_ c: Catalog, _ changes: [(cluster: Int, offset: String?)], keepClock: Bool = false) {
        try? c.transaction {
            let shas = try c.prepare("SELECT f.sha256 FROM member m JOIN file f ON f.id = m.file_id WHERE m.cluster_id = ? AND f.sha256 IS NOT NULL;")
            let ins = try c.prepare("INSERT OR REPLACE INTO zone_fix(sha, utc_offset, chosen_at, keep_clock) VALUES(?,?,?,?);")
            let del = try c.prepare("DELETE FROM zone_fix WHERE sha = ?;")
            for ch in changes {
                shas.bind(1, ch.cluster)
                var hs: [String] = []
                while shas.step() { if let h = shas.text(0) { hs.append(h) } }
                shas.reset()
                for h in hs {
                    if let o = ch.offset { ins.bind(1, h).bind(2, o).bind(3, Date().timeIntervalSince1970).bind(4, keepClock ? 1 : 0).done(); ins.reset() }
                    else { del.bind(1, h).done(); del.reset() }
                }
            }
            shas.finalize(); ins.finalize(); del.finalize()
        }
    }

    static func rules(_ c: Catalog) -> [Resolver.PlaceRule] {
        var out: [Resolver.PlaceRule] = []
        if let st = try? c.prepare("SELECT id, folder, day_from, day_to, lat, lon, label FROM place_rule ORDER BY id;") {
            while st.step() {
                out.append(Resolver.PlaceRule(id: st.int(0), folder: st.text(1),
                                              dayFrom: st.isNull(2) ? nil : st.int(2), dayTo: st.isNull(3) ? nil : st.int(3),
                                              lat: st.double(4), lon: st.double(5), label: st.text(6) ?? ""))
            }
            st.finalize()
        }
        return out
    }

    static func addRule(_ c: Catalog, folder: String?, from: Int?, to: Int?, lat: Double, lon: Double, label: String) {
        try? c.transaction {
            let st = try c.prepare("INSERT INTO place_rule(folder, day_from, day_to, lat, lon, label, created) VALUES(?,?,?,?,?,?,?);")
            st.bind(1, folder).bind(2, from).bind(3, to).bind(4, lat).bind(5, lon).bind(6, label)
              .bind(7, Date().timeIntervalSince1970).done(); st.finalize()
        }
    }

    static func deleteRule(_ c: Catalog, _ id: Int) {
        try? c.transaction { let st = try c.prepare("DELETE FROM place_rule WHERE id = ?;")
                             st.bind(1, id).done(); st.finalize() }
    }

    static func picks(_ c: Catalog) -> [Int: String] {
        var out: [Int: String] = [:]
        if let st = try? c.prepare("SELECT day, utc_offset FROM zone_pick;") {
            while st.step() { if let o = st.text(1) { out[st.int(0)] = o } }
            st.finalize()
        }
        return out
    }

    // MARK: dials, as stored

    static func params(_ c: Catalog) -> Resolver.Params {
        guard let json = c.setting("resolver"), let d = json.data(using: .utf8),
              let p = try? JSONDecoder().decode(Resolver.Params.self, from: d) else { return .init() }
        return p
    }
    static func setParams(_ c: Catalog, _ p: Resolver.Params) {
        if let d = try? JSONEncoder().encode(p), let s = String(data: d, encoding: .utf8) {
            c.setSetting("resolver", s)
        }
    }
    static func radius(_ c: Catalog) -> Int { c.setting("radius").flatMap(Int.init) ?? 4 }
    static func setRadius(_ c: Catalog, _ r: Int) { c.setSetting("radius", String(r)) }

    struct Resolution {
        var inputs: [Resolver.Input]
        var resolved: [Resolver.Resolved]
        var stats: Resolver.Stats
    }

    /// Resolve time, place and zone, honouring the person's choices, and store it.
    @discardableResult
    static func resolve(_ c: Catalog) throws -> Resolution {
        let inputs = claims(c)
        let (resolved, stats) = Resolver.resolve(inputs, picks: picks(c), params: params(c), fixes: fixes(c),
                                                 rules: rules(c), manual: Manual.load(c))
        try c.transaction {
            try c.run("DELETE FROM resolution;")
            let st = try c.prepare("""
                INSERT INTO resolution(cluster_id, local_time, time_source, utc_offset,
                    zone_source, lat, lon, place_source, instant)
                VALUES(?,?,?,?,?,?,?,?,?);
                """)
            for r in resolved {
                st.bind(1, r.clusterID).bind(2, r.localTime).bind(3, r.timeSource)
                  .bind(4, r.utcOffset).bind(5, r.zoneSource)
                  .bind(6, r.lat).bind(7, r.lon).bind(8, r.placeSource)
                  .bind(9, r.instant)
                st.done(); st.reset()
            }
            st.finalize()
        }
        return Resolution(inputs: inputs, resolved: resolved, stats: stats)
    }
}
