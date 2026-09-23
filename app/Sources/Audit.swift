import Foundation

/// Contradictions in the resolved timezones (PLAN §11, M5: "zone audit reports 0").
///
/// A contradiction is not a guess being wrong somewhere unknown; it is two pieces of
/// the result that cannot both be true. Three checks, all built on geography,
/// because a timezone is a property of a place and a time:
///  1. **Same place, same half hour, two offsets.** Nobody changes timezone without
///     moving. Exactly one hour apart around a DST change is named as such. Which
///     one is wrong is settled by the place's civil time where a town is near, else
///     by the photographs around them.
///  2. **An offset the place's clock disputes.** A photograph measured within 25 km
///     of a town, recording an offset that town's clocks did not show at that
///     instant (GeoNames zone + the system tz database, offline).
///  3. **An offset the place itself disputes.** Where no town is near but several
///     photographs taken in the same spot that month record their own offset and
///     agree, one that says otherwise is flagged.
///
/// Whole sessions go wrong together — a camera left on home time tags forty
/// photographs in a row — so a majority is only trusted where the clock is unknown.
enum Audit {

    struct Finding: Identifiable, Equatable {
        enum Kind: String { case samePlaceTwoZones = "same place, same half hour, two timezones"
                            case placeClock = "clocks there showed a different timezone"
                            case placeDisagrees = "the place records a different timezone" }
        let kind: Kind
        let clusterID: Int
        let other: Int?                // the photograph it contradicts, when there is one
        let offset: String, expected: String
        let note: String
        var id: String { "\(kind.rawValue)|\(clusterID)|\(other ?? 0)" }
    }

    static let windowSeconds = 1800.0
    static let nearKM = 50.0

    /// How many placed photographs within the window and distance of `r` record `offset`.
    static func support(_ offset: String, near r: Resolver.Resolved, in placed: [Resolver.Resolved]) -> Int {
        placed.filter { $0.utcOffset == offset && abs($0.instant! - r.instant!) <= windowSeconds
                        && Resolver.haversineKM(r.lat!, r.lon!, $0.lat!, $0.lon!) <= nearKM }.count
    }

    /// The civil offset at a photograph's measured place and instant; nil when the
    /// place was inferred (it may be a day's or folder's place, not this photo's) or
    /// no town is within 25 km.
    static func civilOffset(_ r: Resolver.Resolved) -> String? {
        guard Resolver.readPlace(r.placeSource), let la = r.lat, let lo = r.lon, let i = r.instant else { return nil }
        return Gazetteer.civilOffset(la, lo, at: i)
    }
    /// A zone a person set is theirs; the audit points out contradictions, not choices.
    static func personal(_ zoneSource: String) -> Bool { zoneSource.hasPrefix("you ") }

    static func zones(_ rs: [Resolver.Resolved]) -> [Finding] {
        var out: [Finding] = []
        let placed = rs.filter { $0.instant != nil && $0.utcOffset != nil && $0.lat != nil }
            .sorted { $0.instant! < $1.instant! }

        // 1. neighbours in time, near in space, different offsets
        for (i, a) in placed.enumerated() {
            var j = i + 1
            while j < placed.count, placed[j].instant! - a.instant! <= windowSeconds {
                let b = placed[j]; j += 1
                guard a.utcOffset != b.utcOffset,
                      Resolver.haversineKM(a.lat!, a.lon!, b.lat!, b.lon!) <= nearKM else { continue }
                let gap = abs(Resolver.offsetSeconds(a.utcOffset) - Resolver.offsetSeconds(b.utcOffset))
                // The place's own clock decides, if a town is near. Failing that, blame the
                // one whose zone was worked out, if only one was. Otherwise the photographs
                // around them decide: the offset fewer of them share is the odd one out.
                // A tie cannot be settled here, so both are put to the person.
                let aRead = Resolver.readZone(a.zoneSource), bRead = Resolver.readZone(b.zoneSource)
                let civil = civilOffset(a) ?? civilOffset(b)
                var blame: [(Resolver.Resolved, Resolver.Resolved)]
                if let c = civil, (a.utcOffset == c) != (b.utcOffset == c) { blame = a.utcOffset == c ? [(b, a)] : [(a, b)] }
                else if aRead != bRead { blame = aRead ? [(b, a)] : [(a, b)] }
                else {
                    let sa = support(a.utcOffset!, near: a, in: placed), sb = support(b.utcOffset!, near: a, in: placed)
                    blame = sa < sb ? [(a, b)] : sb < sa ? [(b, a)] : [(a, b), (b, a)]
                }
                for (bad, good) in blame {
                    out.append(Finding(kind: .samePlaceTwoZones, clusterID: bad.clusterID, other: good.clusterID,
                                       offset: bad.utcOffset!, expected: good.utcOffset!,
                                       note: gap == 3600 ? "one hour apart — a daylight-saving change, or a clock not updated"
                                                         : "\(Int((bad.instant! - good.instant!).magnitude / 60)) minutes and \(Int(Resolver.haversineKM(a.lat!, a.lon!, b.lat!, b.lon!))) km apart"))
                }
            }
        }

        // 2. the place's clock: measured near a town, an offset its clocks never showed
        for r in placed where !personal(r.zoneSource) {
            guard let c = civilOffset(r), c != r.utcOffset else { continue }
            out.append(Finding(kind: .placeClock, clusterID: r.clusterID, other: nil,
                               offset: r.utcOffset!, expected: c,
                               note: "clocks near \(Gazetteer.describe(r.lat!, r.lon!) ?? "there") showed \(c) at that moment"))
        }

        // 3. the place's own record, where no town is near to say, from photographs that carry their offset
        struct Obs { let lat: Double; let lon: Double; let month: String; let off: String }
        var obs: [Obs] = []
        for r in placed where Resolver.readZone(r.zoneSource) && Resolver.readPlace(r.placeSource) {
            obs.append(Obs(lat: r.lat!, lon: r.lon!, month: String(r.localTime?.prefix(7) ?? ""), off: r.utcOffset!))
        }
        // bucket by ~0.5° cells so this stays linear
        var cells: [String: [Obs]] = [:]
        func cell(_ la: Double, _ lo: Double) -> String { "\(Int((la * 2).rounded(.down))),\(Int((lo * 2).rounded(.down)))" }
        for o in obs { cells[cell(o.lat, o.lon), default: []].append(o) }
        for r in placed where !personal(r.zoneSource) && civilOffset(r) == nil {
            let month = String(r.localTime?.prefix(7) ?? "")
            var tally: [String: Int] = [:]
            for dx in -1...1 { for dy in -1...1 {
                let k = "\(Int((r.lat! * 2).rounded(.down)) + dx),\(Int((r.lon! * 2).rounded(.down)) + dy)"
                for o in cells[k] ?? [] where o.month == month
                    && Resolver.haversineKM(r.lat!, r.lon!, o.lat, o.lon) <= nearKM { tally[o.off, default: 0] += 1 }
            } }
            // only a clear, consistent record may dispute: three or more, unanimous
            guard tally.count == 1, let (off, n) = tally.first, n >= 3, off != r.utcOffset else { continue }
            out.append(Finding(kind: .placeDisagrees, clusterID: r.clusterID, other: nil,
                               offset: r.utcOffset!, expected: off,
                               note: "\(n) photographs taken within \(Int(nearKM)) km that month all record \(off)"))
        }
        // one finding per photograph, the more specific first
        var seen = Set<Int>()
        return out.filter { seen.insert($0.clusterID).inserted }
    }
}
