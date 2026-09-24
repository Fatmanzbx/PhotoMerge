import Foundation

/// The identity cascade, as a pure function over facts (PLAN §7.1).
/// Kept out of `Engine` so it can be tested without a UI or an actor.
enum Clusterer {

    struct Item {
        let id: Int
        let sha: String?
        let pixel: String?
        let dhash: UInt64?
        let bytes: Int
        let width: Int
        let height: Int
        /// 64x64 grayscale, for verification. Without it a candidate cannot be
        /// confirmed and is left unmerged.
        var thumb: [UInt8]? = nil
        /// As recorded, "YYYY:MM:DD HH:MM:SS". Two copies of one photograph carry
        /// the same one; two frames of a burst do not.
        var capturedAt: String? = nil
        var pixels: Int { width * height }
    }

    /// Mean absolute difference between two equal-length grayscale buffers, 0...255.
    static func mae(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }

    /// Box-downsample a square grayscale buffer to `to`x`to`.
    static func shrink(_ g: [UInt8], from: Int, to: Int) -> [UInt8] {
        guard from > to, from * from == g.count, from % to == 0 else { return g }
        let f = from / to
        var out = [UInt8](repeating: 0, count: to * to)
        for y in 0..<to {
            for x in 0..<to {
                var sum = 0
                for dy in 0..<f { for dx in 0..<f { sum += Int(g[(y*f+dy)*from + x*f+dx]) } }
                out[y*to + x] = UInt8(sum / (f*f))
            }
        }
        return out
    }

    enum Verdict: Equatable { case confirm, reject, review }

    // MARK: - tier D, video

    struct Video {
        let id: Int
        let duration: Double
        let frames: [UInt64]
        let bytes: Int
        let pixels: Int
        var thumb: [UInt8]? = nil
        var capturedAt: String? = nil
    }

    /// Containers round differently, so an exact duration match is too strict.
    static var durationTolerance = 0.15
    /// Per-frame dHash distance allowed. Generous because a re-encode shifts the
    /// sampled instant slightly, and a frame 40 ms away looks different.
    static var frameDistance = 8

    /// Two videos are the same recording when the duration agrees and every sampled
    /// frame agrees. Both conditions matter: duration alone matches any two clips of
    /// the same length, frames alone match a static scene.
    static func sameRecording(_ a: Video, _ b: Video) -> Bool {
        guard abs(a.duration - b.duration) <= durationTolerance else { return false }
        guard !a.frames.isEmpty, a.frames.count == b.frames.count else { return false }
        for (x, y) in zip(a.frames, b.frames) where BKTree.distance(x, y) > frameDistance {
            return false
        }
        return true
    }

    /// Group videos. Same separation guard as stills: two clips recorded at different
    /// instants are different recordings however alike they look.
    static func clusterVideos(_ vids: [Video]) -> Report {
        var r = Report(groups: [])
        guard !vids.isEmpty else { return r }
        var ds = DisjointSet(vids.count)

        // bucket by rounded duration so this stays near-linear instead of N^2
        var byDur: [Int: [Int]] = [:]
        for (i, v) in vids.enumerated() { byDur[Int(v.duration.rounded()), default: []].append(i) }

        for (i, v) in vids.enumerated() {
            let d = Int(v.duration.rounded())
            for bucket in [d - 1, d, d + 1] {
                for j in byDur[bucket] ?? [] where j > i {
                    let w = vids[j]
                    if let ta = v.capturedAt, let tb = w.capturedAt, ta != tb {
                        r.separated += 1; continue
                    }
                    guard sameRecording(v, w) else { r.rejected += 1; continue }
                    // one more gate: the middle frame must survive the slope test too
                    if let ta = v.thumb, let tb = w.thumb {
                        switch verify(ta, tb) {
                        case .confirm: break
                        case .review:  r.needsReview += 1; continue
                        case .reject:  r.rejected += 1; continue
                        }
                    }
                    if ds.find(i) != ds.find(j) { r.tierD += 1 }
                    ds.union(i, j)
                }
            }
        }

        var comps: [Int: [Int]] = [:]
        for i in 0..<vids.count { comps[ds.find(i), default: []].append(i) }
        for (_, members) in comps {
            let ranked = members.sorted {
                let a = vids[$0], b = vids[$1]
                if a.pixels != b.pixels { return a.pixels > b.pixels }
                if a.bytes != b.bytes { return a.bytes > b.bytes }
                return a.id < b.id
            }
            let wasted = ranked.dropFirst().reduce(0) { $0 + vids[$1].bytes }
            r.groups.append(Group(members: ranked, canonical: ranked[0],
                                  method: members.count == 1 ? "single" : "same recording",
                                  wasted: wasted))
            r.longestChain = max(r.longestChain, members.count)
        }
        r.groups.sort { $0.wasted > $1.wasted }
        return r
    }

    /// Comparing at ONE resolution is not enough. Measured on a real library, all
    /// eleven candidate pairs scored under 8 at 16x16 — including nine pairs of
    /// genuinely different photographs. The *slope* separates them:
    ///
    ///     flat and low   → one photograph, re-encoded        → confirm
    ///     flat and mid   → same frame, different grade       → review (a variant)
    ///     rising         → detail diverges, different photos → reject
    static let confirmMAE = 4.0     // at 64x64
    static let maxSlope   = 2.0     // 64x64 minus 16x16

    /// The two numbers `verify` decides on, exposed so the UI can show them.
    static func measure(_ a: [UInt8], _ b: [UInt8]) -> (hi: Double, lo: Double) {
        (mae(a, b), mae(shrink(a, from: 64, to: 16), shrink(b, from: 64, to: 16)))
    }

    static func verify(_ a: [UInt8], _ b: [UInt8]) -> Verdict {
        let (hi, lo) = measure(a, b)
        let slope = hi - lo
        if slope > maxSlope { return .reject }          // different photographs
        if hi <= confirmMAE { return .confirm }         // one photograph, re-encoded
        return .review                                 // flat but not identical: a grade
    }

    /// Separation guard, before any pixel comparison (INHERITED §2.10).
    /// Copies of one photograph share a capture instant. Frames of a burst do not,
    /// however similar they look — nine shots of one scene minutes apart scored
    /// MAE 8 on a real library and were wrongly merged until this ran first.
    /// Returns true when the pair is *provably* two different photographs.
    static func differentMoments(_ a: Item, _ b: Item) -> Bool {
        guard let ta = a.capturedAt, let tb = b.capturedAt else { return false }
        return ta != tb
    }

    /// Why two items can never be one photograph, whatever their pixels say — or nil
    /// when nothing rules it out. Every tier asks this before it joins anything.
    static func incompatible(_ a: Item, _ b: Item) -> Pair.Outcome? {
        if differentMoments(a, b) { return .burst }
        if !sameShape(a, b) { return .rejected }
        // two blank frames agree on every pixel and prove nothing; only a shared
        // capture instant can say they are one photograph
        if let t = a.thumb, featureless(t), a.capturedAt == nil || b.capturedAt == nil { return .unverifiable }
        if let t = b.thumb, featureless(t), a.capturedAt == nil || b.capturedAt == nil { return .unverifiable }
        return nil
    }

    /// Two copies of one photograph keep its proportions (a rotation is normalised
    /// before hashing). A 4:3 frame and a square one are not the same image, whatever
    /// a square grid says. Unknown dimensions cannot object.
    static func sameShape(_ a: Item, _ b: Item) -> Bool {
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return true }
        let ra = Double(max(a.width, a.height)) / Double(min(a.width, a.height))
        let rb = Double(max(b.width, b.height)) / Double(min(b.width, b.height))
        return abs(ra - rb) / max(ra, rb) <= 0.02
    }

    /// A thumb with almost no variation — a black frame, a blank wall, a white
    /// page — matches every other such frame. It is not evidence of anything.
    static func featureless(_ g: [UInt8]) -> Bool {
        guard !g.isEmpty else { return true }
        let mean = Double(g.reduce(0) { $0 + Int($1) }) / Double(g.count)
        let variance = g.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(g.count)
        return variance.squareRoot() < 3
    }

    struct Group {
        var members: [Int]        // indices into the input array
        var canonical: Int        // index of the copy to keep
        var method: String        // exact | pixel | similar | single
        var wasted: Int           // bytes recoverable
    }

    /// One tier C candidate and what became of it. Every candidate is kept, so the
    /// Dials pane can show samples and the boundary cases can be put to a person.
    struct Pair: Equatable {
        enum Outcome: String, Equatable {
            case merged        // pixels confirmed: one photograph, re-encoded
            case variant       // same frame, different grade: a person must decide
            case rejected      // detail diverges: different photographs
            case burst         // different capture instants: never the same photograph
            case unverifiable  // no pixels on one side to check against
            case youSame       // a person said: same photograph
            case youDifferent  // a person said: different photographs
        }
        let a: Int, b: Int              // Item ids (file ids), a < b
        let distance: Int               // dHash Hamming distance
        let outcome: Outcome
        let maeHi: Double?, maeLo: Double?
    }

    /// A person's verdict on a pair, keyed by the two file ids, smaller first.
    struct PairKey: Hashable { let a: Int, b: Int
        init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) }
    }

    struct Report {
        var groups: [Group]
        var pairs: [Pair] = []    // every tier C candidate, once per unordered pair
        var tierA = 0             // unions made by content hash
        var tierB = 0             // unions made by pixel hash
        var tierC = 0             // unions made by perceptual distance, verified
        var tierD = 0             // unions made by video duration + frames
        var separated = 0         // candidates rejected as different moments (bursts)
        var rejected = 0          // candidates the pixel check threw out
        var needsReview = 0       // flat but not identical — probably an edit
        var unverifiable = 0      // candidates with no thumb on one side
        var longestChain = 0      // the number that matters for radius safety
        mutating func count(_ why: Pair.Outcome) {
            switch why { case .burst: separated += 1; case .rejected: rejected += 1; default: unverifiable += 1 }
        }
    }

    /// Most-certain tier first. Each tier only ever *adds* unions, so a later,
    /// weaker tier can never split what a stronger one joined.
    /// `decisions` are verdicts a person gave on boundary pairs: `true` joins the
    /// pair whatever the dials say, `false` stops tier C joining it directly. They
    /// cannot split tiers A and B — byte- or pixel-identical files are one image.
    static func cluster(_ items: [Item], radius: Int,
                        decisions: [PairKey: Bool] = [:]) -> Report {
        var ds = DisjointSet(items.count)
        var r = Report(groups: [])
        guard !items.isEmpty else { return r }

        // Tier A — byte-identical copies.
        var bySha: [String: Int] = [:]
        for (i, it) in items.enumerated() {
            guard let s = it.sha else { continue }
            if let j = bySha[s] { ds.union(j, i); r.tierA += 1 } else { bySha[s] = i }
        }

        // Tier B — same image content, different bytes: a re-encode or a metadata
        // rewrite. This is what makes re-exporting a source cheap (INHERITED §3.1).
        // The hash is a 64×64 grey grid, so it also matches two black frames, or a
        // frame and its crop scaled to the same grid: the same guards as tier C
        // apply — different capture instants, a different shape, or nothing to see
        // in the picture, and the pair stays apart (review finding 1).
        var byPixel: [String: [Int]] = [:]
        for (i, it) in items.enumerated() {
            guard let p = it.pixel else { continue }
            if let js = byPixel[p] {
                var joined = false
                for j in js {
                    let other = items[j]
                    if let why = incompatible(it, other) { r.count(why); continue }
                    ds.union(j, i); joined = true; break
                }
                if joined { r.tierB += 1 }
                byPixel[p]!.append(i)
            } else { byPixel[p] = [i] }
        }

        // Tier C — perceptual neighbours within the radius dial, each VERIFIED.
        if radius > 0 {
            let tree = BKTree()
            for (i, it) in items.enumerated() { if let d = it.dhash { tree.add(d, i) } }
            for (i, it) in items.enumerated() {
                guard let d = it.dhash else { continue }
                // j > i: each unordered pair is judged once, and recorded once
                for j in tree.query(d, radius: radius) where j > i {
                    let other = items[j]
                    let dist = (d ^ (other.dhash ?? d)).nonzeroBitCount
                    func record(_ o: Pair.Outcome, _ m: (hi: Double, lo: Double)? = nil) {
                        r.pairs.append(Pair(a: min(it.id, other.id), b: max(it.id, other.id),
                                            distance: dist, outcome: o,
                                            maeHi: m?.hi, maeLo: m?.lo))
                    }
                    let m = (it.thumb != nil && other.thumb != nil) ? measure(it.thumb!, other.thumb!) : nil
                    if let said = decisions[PairKey(it.id, other.id)] {
                        if said { ds.union(i, j); record(.youSame, m) } else { record(.youDifferent, m) }
                        continue
                    }
                    // The same guards as tier B, before any pixel comparison. Union-find
                    // is transitive: a guard that one tier skips is no guard at all — two
                    // dated black frames stayed apart in tier B and were joined here, each
                    // to an undated blank GIF (review round 2, R1).
                    if let why = incompatible(it, other) { r.count(why); record(why, m); continue }
                    guard let ta = it.thumb, let tb = other.thumb else {
                        r.unverifiable += 1; record(.unverifiable); continue
                    }
                    switch verify(ta, tb) {
                    case .confirm:
                        if ds.find(i) != ds.find(j) { r.tierC += 1 }
                        ds.union(i, j); record(.merged, m)
                    case .review:
                        r.needsReview += 1; record(.variant, m)   // never merged automatically
                    case .reject:
                        r.rejected += 1; record(.rejected, m)
                    }
                }
            }
        }
        // A "same" verdict stands even outside the radius: the person looked.
        if !decisions.isEmpty {
            var index: [Int: Int] = [:]
            for (i, it) in items.enumerated() { index[it.id] = i }
            for (k, same) in decisions where same {
                if let i = index[k.a], let j = index[k.b], ds.find(i) != ds.find(j) {
                    ds.union(i, j)
                    if !r.pairs.contains(where: { $0.a == k.a && $0.b == k.b }) {
                        r.pairs.append(Pair(a: k.a, b: k.b, distance: -1, outcome: .youSame,
                                            maeHi: nil, maeLo: nil))
                    }
                }
            }
        }

        // Materialise components.
        var comps: [Int: [Int]] = [:]
        for i in 0..<items.count { comps[ds.find(i), default: []].append(i) }

        for (_, members) in comps {
            // Best copy: more pixels, then larger file (PLAN §7.1).
            let ranked = members.sorted {
                let a = items[$0], b = items[$1]
                if a.pixels != b.pixels { return a.pixels > b.pixels }
                if a.bytes != b.bytes { return a.bytes > b.bytes }
                return a.id < b.id                      // deterministic tiebreak
            }
            let wasted = ranked.dropFirst().reduce(0) { $0 + items[$1].bytes }
            let shas = Set(members.compactMap { items[$0].sha })
            let pxs  = Set(members.compactMap { items[$0].pixel })
            let ids = Set(members.map { items[$0].id })
            let byYou = r.pairs.contains { $0.outcome == .youSame && ids.contains($0.a) && ids.contains($0.b) }
            let method: String = members.count == 1 ? "single"
                : shas.count == 1 ? "exact"
                : pxs.count == 1 ? "same image"
                : byYou ? "chosen" : "similar"
            r.groups.append(Group(members: ranked, canonical: ranked[0],
                                  method: method, wasted: wasted))
            r.longestChain = max(r.longestChain, members.count)
        }
        r.groups.sort { $0.wasted > $1.wasted }
        return r
    }
}
