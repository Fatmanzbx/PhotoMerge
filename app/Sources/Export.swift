import Foundation

/// The findings, as a file the person chose. One record per asset: what it is,
/// which copy is kept, every duplicate, and each fact with where it came from.
///
/// This is the only thing v1 writes outside its own catalog, and it writes only
/// to the path picked in a save panel — never beside or over a photograph.
enum Export {

    struct Record: Codable, Equatable {
        var asset: Int
        var kept: String
        var duplicates: [String]
        /// The motion clip of a Live Photo or motion photo — part of the photograph.
        var companion: String? = nil
        var recoverableBytes: Int
        var localTime: String?
        var utcOffset: String?
        /// ISO 8601 in UTC — present only when the zone is known. A wall clock with
        /// no zone is not an instant, and exporting one as UTC would invent it.
        var instantUTC: String?
        var timeSource: String
        var zoneSource: String
        var latitude: Double?
        var longitude: Double?
        var placeSource: String
        /// The nearest town, from the offline gazetteer — a convenience for reading.
        var placeName: String? = nil
    }

    static func records(_ c: Catalog) -> [Record] {
        var byAsset: [Int: Record] = [:]
        guard let st = try? c.prepare("""
            SELECT c.id, c.wasted, m.role, f.path, r.local_time, r.utc_offset, r.instant,
                   r.time_source, r.zone_source, r.lat, r.lon, r.place_source
            FROM cluster c JOIN member m ON m.cluster_id = c.id JOIN file f ON f.id = m.file_id
            LEFT JOIN resolution r ON r.cluster_id = c.id
            ORDER BY c.id, CASE m.role WHEN 'canonical' THEN 0 ELSE 1 END, f.path;
            """) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        while st.step() {
            let id = st.int(0)
            let path = st.text(3) ?? ""
            let role = st.text(2) ?? ""
            if var rec = byAsset[id] {
                switch role {
                case "canonical": rec.kept = path
                case "companion": rec.companion = path
                default: rec.duplicates.append(path)
                }
                byAsset[id] = rec
                continue
            }
            let instant: String? = st.isNull(6) ? nil
                : iso.string(from: Date(timeIntervalSince1970: st.double(6)))
            byAsset[id] = Record(
                asset: id,
                kept: role == "canonical" ? path : "",
                duplicates: role == "duplicate" ? [path] : [],
                companion: role == "companion" ? path : nil,
                recoverableBytes: st.int(1),
                // a time shown in UTC for want of a zone is not a local time
                localTime: (st.text(7) ?? "").hasSuffix("shown in UTC") ? nil : st.text(4).map(isoLocal),
                utcOffset: st.text(5),
                instantUTC: instant,
                timeSource: st.text(7) ?? "none", zoneSource: st.text(8) ?? "none",
                latitude: st.isNull(9) ? nil : st.double(9),
                longitude: st.isNull(10) ? nil : st.double(10),
                placeSource: st.text(11) ?? "none",
                placeName: st.isNull(9) ? nil : Gazetteer.describe(st.double(9), st.double(10)))
        }
        st.finalize()
        return byAsset.values.sorted { $0.asset < $1.asset }
    }

    /// "2021:03:07 14:22:31" → "2021-03-07T14:22:31", the form spreadsheets parse.
    static func isoLocal(_ exif: String) -> String {
        guard exif.count >= 19 else { return exif }
        var s = Array(exif)
        s[4] = "-"; s[7] = "-"; s[10] = "T"
        return String(s)
    }

    // MARK: CSV

    static let columns = ["asset", "kept", "duplicates", "companion", "recoverable_bytes", "local_time",
                          "utc_offset", "instant_utc", "time_source", "zone_source",
                          "latitude", "longitude", "place_source", "place_name"]

    /// RFC 4180. Duplicate paths share one cell, separated by a newline inside the
    /// quotes — a character no filename separator would ever be confused with.
    static func csv(_ rs: [Record]) -> String {
        var out = columns.joined(separator: ",") + "\r\n"
        for r in rs {
            // Only text that came from outside — paths — is defused. Offsets and
            // coordinates are formatted here and legitimately start with "-".
            let cells: [String] = [
                String(r.asset), field(r.kept, defuse: true),
                field(r.duplicates.joined(separator: "\n"), defuse: true),
                field(r.companion ?? "", defuse: true),
                String(r.recoverableBytes), r.localTime ?? "", r.utcOffset ?? "",
                r.instantUTC ?? "", field(r.timeSource), field(r.zoneSource),
                r.latitude.map { String(format: "%.6f", $0) } ?? "",
                r.longitude.map { String(format: "%.6f", $0) } ?? "",
                field(r.placeSource), field(r.placeName ?? ""),
            ]
            out += cells.joined(separator: ",") + "\r\n"
        }
        return out
    }

    static func field(_ s: String, defuse: Bool = false) -> String {
        // A leading = + - @ makes a spreadsheet evaluate the cell as a formula. A
        // path is data, so it is quoted and prefixed rather than executed.
        let risky = defuse && (s.first.map { "=+-@".contains($0) } ?? false)
        let needsQuotes = risky || s.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        guard needsQuotes else { return s }
        let body = (risky ? "'" : "") + s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"" + body + "\""
    }

    // MARK: JSON

    static func json(_ rs: [Record]) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(rs)
    }
}
