import Foundation

/// Place names, offline. 34,148 cities of 15,000+ people from GeoNames
/// (https://www.geonames.org, CC BY 4.0), bundled as Resources/places.tsv, so
/// "38.7251°N 9.1498°W" reads as "Lisbon, Portugal" and "Lisbon" can be typed
/// instead of looked up. Nothing is ever fetched: the app stays offline.
enum Gazetteer {

    struct Place: Equatable {
        let name: String, ascii: String
        let lat: Double, lon: Double
        let region: String, country: String
        let population: Int
        let local: [String]              // Chinese, Japanese, Korean names
        var zone: String = ""            // IANA time zone, e.g. "Asia/Shanghai"
        /// The names as searched — case and accents folded — computed once at load.
        var folded: [String] = []
        var label: String { country.isEmpty || country == name ? name : "\(name), \(country)" }
        var fullLabel: String {
            [name, region == name ? "" : region, country].filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    // MARK: loading

    static func locate() -> URL? {
        var candidates: [URL] = []
        if let r = Bundle.main.url(forResource: "places", withExtension: "tsv") { candidates.append(r) }
        if let e = ProcessInfo.processInfo.environment["PM_PLACES"] { candidates.append(URL(fileURLWithPath: e)) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/places.tsv"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Loaded once, on first use. Empty (and every lookup nil) if the file is absent.
    static let places: [Place] = {
        guard let url = locate(), let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [Place] = []
        out.reserveCapacity(35_000)
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8, let la = Double(f[2]), let lo = Double(f[3]) else { continue }
            out.append(Place(name: f[0], ascii: f[1].isEmpty ? f[0] : f[1], lat: la, lon: lo,
                             region: f[4], country: f[5], population: Int(f[6]) ?? 0,
                             local: f[7].isEmpty ? [] : f[7].split(separator: ",").map(String.init),
                             zone: f.count > 8 ? f[8] : "",
                             folded: [fold(f[0]), fold(f[1].isEmpty ? f[0] : f[1])]))
        }
        return out
    }()

    /// One-degree cells, so a nearest lookup looks at nine cells, not 34,000 places.
    private static let grid: [Int: [Int]] = {
        var g: [Int: [Int]] = [:]
        for (i, p) in places.enumerated() { g[cell(p.lat, p.lon), default: []].append(i) }
        return g
    }()
    private static func cell(_ la: Double, _ lo: Double) -> Int {
        Int(floor(la) + 90) * 1000 + Int(floor(lo) + 180)
    }

    // MARK: coordinate → name

    static func nearest(_ lat: Double, _ lon: Double) -> (place: Place, km: Double)? {
        guard !places.isEmpty else { return nil }
        var best: (Place, Double)? = nil
        let la = Int(floor(lat) + 90), lo = Int(floor(lon) + 180)
        for dla in -1...1 { for dlo in -1...1 {
            let k = (la + dla) * 1000 + ((lo + dlo + 360) % 360)
            for i in grid[k] ?? [] {
                let p = places[i]
                let d = Resolver.haversineKM(lat, lon, p.lat, p.lon)
                if best == nil || d < best!.1 { best = (p, d) }
            }
        } }
        return best.map { (place: $0.0, km: $0.1) }
    }

    /// "Lisbon, Portugal"; "near …" a little way out; nil when nothing
    /// is within 60 km — the coordinates then say it better than a wrong name would.
    static func describe(_ lat: Double, _ lon: Double) -> String? {
        guard let n = nearest(lat, lon) else { return nil }
        if n.km <= 15 { return n.place.label }
        if n.km <= 60 { return "near " + n.place.label }
        return nil
    }

    // MARK: coordinate → time zone

    /// The civil offset where a photograph was taken, at the instant it was taken
    /// ("+08:00"), from the nearest town's time zone and the system's tz database —
    /// daylight saving and historical changes included. Nil unless a town is within
    /// `withinKM`: near a zone border, the nearest town may be across it.
    static func civilOffset(_ lat: Double, _ lon: Double, at instant: Double, withinKM: Double = 25) -> String? {
        guard let n = nearest(lat, lon), n.km <= withinKM, let tz = TimeZone(identifier: n.place.zone) else { return nil }
        return Resolver.offsetString(Double(tz.secondsFromGMT(for: Date(timeIntervalSince1970: instant))))
    }

    // MARK: name → places

    /// Places whose name begins with what was typed — in English, without accents,
    /// or in Chinese, Japanese or Korean. Exact names first, then the most populous.
    static func search(_ query: String, limit: Int = 8) -> [Place] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard q.count >= 2 || q.unicodeScalars.contains(where: { $0.value > 0x2E80 }) else { return [] }
        var exact: [Place] = [], prefix: [Place] = []
        for p in places {           // sorted by population already
            let names = p.folded + p.local
            if names.contains(q) { exact.append(p) }
            else if names.contains(where: { $0.hasPrefix(q) }) { prefix.append(p) }
            if exact.count >= limit { break }
        }
        return Array((exact + prefix).prefix(limit))
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
