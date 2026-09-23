import Foundation

/// What a dial *would* do to this collection, before anything is applied
/// (PLAN §8). Pure functions over data already in memory: a preview can never
/// write, and the same code path the real run uses produces the numbers.
enum Preview {

    // MARK: matching radius

    struct RadiusRow: Identifiable, Equatable {
        let radius: Int
        var duplicates = 0          // extra copies that would be merged
        var merged = 0              // tier C pairs confirmed by the pixels
        var variants = 0            // pairs that would be put to you
        var rejected = 0            // look-alikes the pixels threw out
        var bursts = 0              // candidates separated by capture instant
        var longestChain = 1
        var id: Int { radius }
    }

    struct RadiusResult {
        var rows: [RadiusRow] = []
        /// For each radius, the pairs it would merge or ask about, weakest first —
        /// the samples a person should look at before trusting the setting.
        var samples: [Int: [Clusterer.Pair]] = [:]
    }

    static func radii(_ items: [Clusterer.Item], _ radii: [Int],
                      decisions: [Clusterer.PairKey: Bool] = [:]) -> RadiusResult {
        var out = RadiusResult()
        for r in radii {
            let rep = Clusterer.cluster(items, radius: r, decisions: decisions)
            var row = RadiusRow(radius: r)
            row.duplicates = rep.groups.reduce(0) { $0 + max(0, $1.members.count - 1) }
            row.longestChain = max(1, rep.longestChain)
            for p in rep.pairs {
                switch p.outcome {
                case .merged: row.merged += 1
                case .variant: row.variants += 1
                case .rejected: row.rejected += 1
                case .burst: row.bursts += 1
                default: break
                }
            }
            out.rows.append(row)
            out.samples[r] = weakestFirst(rep.pairs.filter { $0.outcome == .merged || $0.outcome == .variant })
        }
        return out
    }

    /// What the setting *does* comes first: merges, the one nearest the threshold
    /// first, since that is the one that could be wrong. Then what it would *ask*,
    /// most alike first — the ones a person is likeliest to call the same.
    static func weakestFirst(_ ps: [Clusterer.Pair]) -> [Clusterer.Pair] {
        ps.sorted {
            let am = $0.outcome == .merged, bm = $1.outcome == .merged
            if am != bm { return am }
            let a = $0.maeHi ?? 0, b = $1.maeHi ?? 0
            if a != b { return am ? a > b : a < b }
            return ($0.a, $0.b) < ($1.a, $1.b)
        }
    }

    // MARK: place dials

    struct PlaceChange: Identifiable, Equatable {
        enum Kind: String { case gained, lost, moved }
        let clusterID: Int
        let localTime: String?
        let kind: Kind
        let before: String          // provenance before
        let after: String           // provenance after
        let km: Double?             // how far it moved, when it moved
        var id: Int { clusterID }
    }

    struct PlaceResult: Equatable {
        var located = 0, sameDay = 0, nearest = 0, declined = 0
        var changes: [PlaceChange] = []
    }

    /// Resolve with `candidate` and report what differs from `current`, riskiest
    /// first: places gained on the thinnest evidence, then the ones that moved.
    static func places(_ inputs: [Resolver.Input], picks: [Int: String],
                       current: [Resolver.Resolved], candidate: Resolver.Params) -> PlaceResult {
        let (res, st) = Resolver.resolve(inputs, picks: picks, params: candidate)
        var r = PlaceResult(located: st.located, sameDay: st.placeFromDay,
                            nearest: st.placeFromNeighbour, declined: st.declinedDaySpansTooFar)
        var before: [Int: Resolver.Resolved] = [:]
        for x in current { before[x.clusterID] = x }
        for a in res {
            guard let b = before[a.clusterID] else { continue }
            switch (b.lat != nil, a.lat != nil) {
            case (false, true):
                r.changes.append(.init(clusterID: a.clusterID, localTime: a.localTime, kind: .gained,
                                       before: b.placeSource, after: a.placeSource, km: nil))
            case (true, false):
                r.changes.append(.init(clusterID: a.clusterID, localTime: a.localTime, kind: .lost,
                                       before: b.placeSource, after: a.placeSource, km: nil))
            case (true, true):
                let km = Resolver.haversineKM(b.lat!, b.lon!, a.lat!, a.lon!)
                if km > 0.05 {
                    r.changes.append(.init(clusterID: a.clusterID, localTime: a.localTime, kind: .moved,
                                           before: b.placeSource, after: a.placeSource, km: km))
                }
            default: break
            }
        }
        let order: [PlaceChange.Kind: Int] = [.gained: 0, .moved: 1, .lost: 2]
        r.changes.sort {
            if $0.kind != $1.kind { return order[$0.kind]! < order[$1.kind]! }
            if ($0.km ?? 0) != ($1.km ?? 0) { return ($0.km ?? 0) > ($1.km ?? 0) }
            return $0.clusterID < $1.clusterID
        }
        return r
    }
}
