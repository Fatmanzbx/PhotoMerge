import Foundation

/// Facts a person typed in for photographs that carry none: a day, a place, or
/// both, entered for many at once from the Fill in pane.
///
/// Stored by content hash, like every other choice, so they survive a rescan.
/// They never overrule what a file records: an entered day replaces only a missing
/// date or a file-date guess, an entered place only a missing or worked-out one.
enum Manual {

    struct Entry: Equatable {
        var day: String?            // "YYYY:MM:DD" — the precision asked for
        var lat: Double?, lon: Double?
        var confirmed = false       // the place was worked out by the app and accepted, not typed
    }

    /// A date entered to the day is written as noon: the convention for a date
    /// without a time, and the hour least likely to push it onto a neighbouring
    /// day in any timezone.
    static let dayTime = "12:00:00"

    // MARK: parsing what people type

    /// "39.9042, 116.4074", "39.9042 116.4074", "39.9042N 116.4074E",
    /// "39°54'15\"N 116°24'27\"E", "-33.87, 151.21". Returns nil if it is not a real
    /// coordinate — out of range, or (0, 0), which is almost always "no location".
    static func coordinate(_ text: String) -> (lat: Double, lon: Double)? {
        let t = text.uppercased()
            .replacingOccurrences(of: "º", with: "°").replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "”", with: "\"").replacingOccurrences(of: "″", with: "\"")
            .replacingOccurrences(of: "′", with: "'")
        // split into the two halves: on a comma, else on a hemisphere letter, else whitespace
        var parts = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        // no comma: split after the first hemisphere letter, whichever half it ends
        if parts.count != 2, let r = t.range(of: #"[NSEW]"#, options: .regularExpression),
           !t[r.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
            parts = [String(t[..<r.upperBound]), String(t[r.upperBound...])].map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if parts.count != 2 {
            parts = t.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        guard parts.count == 2, var a = angle(parts[0]), var b = angle(parts[1]) else { return nil }
        // Each half's own hemisphere letter sets its sign — before deciding which half is
        // which, or "9.1W, 38.7N" loses its W when the halves are swapped.
        if parts[0].contains("S") || parts[0].contains("W") { a = -abs(a) }
        if parts[1].contains("S") || parts[1].contains("W") { b = -abs(b) }
        // "116.4E 39.9N" — written the other way round
        let swapped = parts[0].contains("E") || parts[0].contains("W") || parts[1].contains("N") || parts[1].contains("S")
        let (la, lo) = swapped ? (b, a) : (a, b)
        guard (-90...90).contains(la), (-180...180).contains(lo), !(la == 0 && lo == 0) else { return nil }
        return (la, lo)
    }

    /// Decimal degrees, or degrees° minutes' seconds".
    private static func angle(_ s: String) -> Double? {
        let nums = s.split(whereSeparator: { !"0123456789.-".contains($0) }).compactMap { Double($0) }
        guard let d = nums.first, nums.count <= 3 else { return nil }
        let m = nums.count > 1 ? nums[1] : 0, sec = nums.count > 2 ? nums[2] : 0
        guard m >= 0, m < 60, sec >= 0, sec < 60 else { return nil }
        return d < 0 ? d - m / 60 - sec / 3600 : d + m / 60 + sec / 3600
    }

    // MARK: storage, by content hash

    static func load(_ c: Catalog) -> [Int: Entry] {
        var out: [Int: Entry] = [:]
        if let st = try? c.prepare("""
            SELECT m.cluster_id, x.day, x.lat, x.lon, x.confirmed FROM manual_fact x
            JOIN file f ON f.sha256 = x.sha JOIN member m ON m.file_id = f.id;
            """) {
            while st.step() {
                var e = out[st.int(0)] ?? Entry()
                if let d = st.text(1) { e.day = d }
                if !st.isNull(2) { e.lat = st.double(2); e.lon = st.double(3); e.confirmed = st.int(4) != 0 }
                out[st.int(0)] = e
            }
            st.finalize()
        }
        return out
    }

    /// Set the day and/or place for these clusters. A nil field is left as it was;
    /// `clearDay` / `clearPlace` remove what was entered.
    static func set(_ c: Catalog, clusters: [Int], day: String? = nil, lat: Double? = nil, lon: Double? = nil,
                    clearDay: Bool = false, clearPlace: Bool = false) {
        try? c.transaction {
            let shas = try c.prepare("SELECT f.sha256 FROM member m JOIN file f ON f.id = m.file_id WHERE m.cluster_id = ? AND f.sha256 IS NOT NULL;")
            let ensure = try c.prepare("INSERT OR IGNORE INTO manual_fact(sha, set_at) VALUES(?,?);")
            let setDay = try c.prepare("UPDATE manual_fact SET day = ?, set_at = ? WHERE sha = ?;")
            let setPlace = try c.prepare("UPDATE manual_fact SET lat = ?, lon = ?, confirmed = 0, set_at = ? WHERE sha = ?;")
            let now = Date().timeIntervalSince1970
            for cid in clusters {
                shas.bind(1, cid)
                var hs: [String] = []
                while shas.step() { if let h = shas.text(0) { hs.append(h) } }
                shas.reset()
                for h in hs {
                    ensure.bind(1, h).bind(2, now).done(); ensure.reset()
                    if let day { setDay.bind(1, day).bind(2, now).bind(3, h).done(); setDay.reset() }
                    if clearDay { setDay.bind(1, nil as String?).bind(2, now).bind(3, h).done(); setDay.reset() }
                    if let lat, let lon { setPlace.bind(1, lat).bind(2, lon).bind(3, now).bind(4, h).done(); setPlace.reset() }
                    if clearPlace { setPlace.bind(1, nil as Double?).bind(2, nil as Double?).bind(3, now).bind(4, h).done(); setPlace.reset() }
                }
            }
            shas.finalize(); ensure.finalize(); setDay.finalize(); setPlace.finalize()
            try c.run("DELETE FROM manual_fact WHERE day IS NULL AND lat IS NULL;")
        }
    }

    /// Accept places the app worked out: each photograph's current place becomes a
    /// fact of its own, marked as confirmed rather than typed, so it reads
    /// "you confirmed it" and no longer waits for a look.
    static func confirm(_ c: Catalog, places: [(cluster: Int, lat: Double, lon: Double)]) {
        try? c.transaction {
            let shas = try c.prepare("SELECT f.sha256 FROM member m JOIN file f ON f.id = m.file_id WHERE m.cluster_id = ? AND f.sha256 IS NOT NULL;")
            let ensure = try c.prepare("INSERT OR IGNORE INTO manual_fact(sha, set_at) VALUES(?,?);")
            let set = try c.prepare("UPDATE manual_fact SET lat = ?, lon = ?, confirmed = 1, set_at = ? WHERE sha = ?;")
            let now = Date().timeIntervalSince1970
            for p in places {
                shas.bind(1, p.cluster)
                var hs: [String] = []
                while shas.step() { if let h = shas.text(0) { hs.append(h) } }
                shas.reset()
                for h in hs {
                    ensure.bind(1, h).bind(2, now).done(); ensure.reset()
                    set.bind(1, p.lat).bind(2, p.lon).bind(3, now).bind(4, h).done(); set.reset()
                }
            }
            shas.finalize(); ensure.finalize(); set.finalize()
        }
    }

    // MARK: places worked out, by area

    /// Places the app worked out rather than read — from the same day, a nearby
    /// photograph or the same folder — awaiting a look. Rules and entries are not.
    static let workedOutSQL = "(r.place_source LIKE 'same day%' OR r.place_source LIKE 'nearest fix%' OR r.place_source LIKE 'same folder%')"
    static func isWorkedOut(_ placeSource: String) -> Bool {
        placeSource.hasPrefix("same day") || placeSource.hasPrefix("nearest fix") || placeSource.hasPrefix("same folder")
    }

    /// Rows gathered into areas: each row joins the first area whose centre is
    /// within `radiusKM`, else starts one. Largest areas first, and within an area
    /// the rows keep their time order. Pure, so it can be tested.
    static func areas(_ rows: [Row], radiusKM: Double = 50) -> [[Row]] {
        var centres: [(lat: Double, lon: Double, n: Int)] = []
        var groups: [[Row]] = []
        for r in rows {
            guard let la = r.lat, let lo = r.lon else { continue }
            if let i = centres.indices.first(where: { Resolver.haversineKM(centres[$0].lat, centres[$0].lon, la, lo) <= radiusKM }) {
                let c = centres[i], n = Double(c.n)
                centres[i] = ((c.lat * n + la) / (n + 1), (c.lon * n + lo) / (n + 1), c.n + 1)
                groups[i].append(r)
            } else {
                centres.append((la, lo, 1)); groups.append([r])
            }
        }
        return groups.sorted { $0.count > $1.count }
    }

    // MARK: the grid's rows

    struct Row: Identifiable, Equatable {
        let id: Int                     // cluster
        let path: String
        let localTime: String?
        let timeSource: String
        let placeSource: String
        var lat: Double? = nil, lon: Double? = nil
        var needsDate: Bool { timeSource == "none" || timeSource.hasPrefix("mtime") || timeSource.contains("date only") }
        var needsPlace: Bool { placeSource == "none" }
        /// A place the app worked out, not yet accepted or replaced.
        var workedOut: Bool { Manual.isWorkedOut(placeSource) }
        var entered: Bool { timeSource.hasPrefix("you entered") || placeSource == "you entered it" || placeSource == "you confirmed it" }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case attention = "Needs a look", either = "No date or no place", date = "No date", place = "No place",
             workedOut = "Place worked out", entered = "Filled in or accepted by you"
        var id: String { rawValue }
        var sql: String {
            switch self {
            case .attention: return "(\(Filter.either.sql) OR \(Manual.workedOutSQL))"
            case .either:  return "(r.time_source = 'none' OR r.time_source LIKE 'mtime%' OR r.time_source LIKE '%date only%' OR r.place_source = 'none')"
            case .date:    return "(r.time_source = 'none' OR r.time_source LIKE 'mtime%' OR r.time_source LIKE '%date only%')"
            case .place:   return "r.place_source = 'none'"
            case .workedOut: return Manual.workedOutSQL
            case .entered: return "(r.time_source LIKE 'you entered%' OR r.place_source IN ('you entered it', 'you confirmed it'))"
            }
        }
    }

    /// Ordered by time, then by folder and name, so a trip's photographs sit
    /// together and can be selected as one sweep.
    static func rows(_ c: Catalog, _ filter: Filter) -> [Row] {
        var out: [Row] = []
        if let st = try? c.prepare("""
            SELECT c.id, f.path, r.local_time, COALESCE(r.time_source,'none'), COALESCE(r.place_source,'none'), r.lat, r.lon
            FROM cluster c JOIN resolution r ON r.cluster_id = c.id
            JOIN member m ON m.cluster_id = c.id AND m.role = 'canonical'
            JOIN file f ON f.id = m.file_id
            WHERE \(filter.sql)
            ORDER BY COALESCE(r.local_time, '9999'), f.rel_path;
            """) {
            while st.step() {
                out.append(Row(id: st.int(0), path: st.text(1) ?? "", localTime: st.text(2),
                               timeSource: st.text(3) ?? "none", placeSource: st.text(4) ?? "none",
                               lat: st.isNull(5) ? nil : st.double(5), lon: st.isNull(6) ? nil : st.double(6)))
            }
            st.finalize()
        }
        return out
    }

    // MARK: selection, as in Finder

    /// Plain click selects one; ⌘ toggles one; ⇧ selects the range from the anchor
    /// (⌘⇧ adds that range to what is selected). Pure, so it can be tested.
    static func click(_ current: Set<Int>, anchor: Int?, order: [Int], id: Int,
                      command: Bool, shift: Bool) -> (selected: Set<Int>, anchor: Int?) {
        if shift, let a = anchor, let ai = order.firstIndex(of: a), let i = order.firstIndex(of: id) {
            let ids = Set(order[min(ai, i)...max(ai, i)])
            return (command ? current.union(ids) : ids, a)
        }
        if command {
            var s = current
            if s.contains(id) { s.remove(id) } else { s.insert(id) }
            return (s, id)
        }
        return ([id], id)
    }
}
