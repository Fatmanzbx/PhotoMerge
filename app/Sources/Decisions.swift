import Foundation

/// "Why is this here?" — the full chain for any asset (PLAN §5, M7).
///
/// Every sentence is generated from what the catalog stores, by a pure function, so
/// it can be tested and cannot drift from what the resolver actually did. The rule
/// the whole app rests on applies here too: say where each fact came from, and say
/// plainly when it was worked out rather than read.
enum Decisions {

    struct FileClaim: Identifiable {
        let id: Int
        let path: String
        let role: String
        let reason: String?
        let capturedAt: String?
        let utcOffset: String?
        let lat: Double?, lon: Double?
        let model: String?
        let bytes: Int, width: Int, height: Int
        var utcInstant: Double? = nil, utcSource: String? = nil
        var nameClock: String? = nil, nameRule: String? = nil
        var sidecar: String? = nil, album: String? = nil
        var name: String { (path as NSString).lastPathComponent }
    }

    struct Asset {
        let clusterID: Int
        let method: String
        let files: [FileClaim]
        let resolution: Resolver.Resolved?
        var canonical: FileClaim? { files.first { $0.role == "canonical" } ?? files.first }
    }

    enum Provenance { case read, inferred, chosen, unknown }

    struct Step: Identifiable {
        let topic: String
        let answer: String
        let why: String
        let provenance: Provenance
        var id: String { topic }
    }

    // MARK: explanation

    static func explain(_ a: Asset, params: Resolver.Params = .init()) -> [Step] {
        [identity(a), time(a), zone(a), place(a, params)]
    }

    static func identity(_ a: Asset) -> Step {
        var step = identityOfCopies(a)
        if let clip = a.files.first(where: { $0.role == "companion" }) {
            step = Step(topic: step.topic,
                        answer: step.answer == "One file" ? "A Live Photo" : step.answer + ", live",
                        why: step.why + " Its motion is \(clip.name), \(clip.reason?.components(separatedBy: " — ").last ?? "paired") — the still and its clip are one photograph.",
                        provenance: step.provenance)
        }
        return step
    }

    static func identityOfCopies(_ a: Asset) -> Step {
        let n = a.files.filter { $0.role != "companion" }.count
        let kept = a.canonical.map { "Kept \($0.name) — \($0.reason?.replacingOccurrences(of: "kept: ", with: "") ?? "the best copy")." } ?? ""
        switch (n, a.method) {
        case (1, _):
            return Step(topic: "Identity", answer: "One file",
                        why: "Nothing else in your sources matched it.", provenance: .read)
        case (_, "exact"):
            return Step(topic: "Identity", answer: "\(n) identical files",
                        why: "Every copy is byte-for-byte the same file. \(kept)", provenance: .read)
        case (_, "same image"):
            return Step(topic: "Identity", answer: "\(n) copies, same pixels",
                        why: "The files differ, but decode to the same image — a re-save or a metadata edit. \(kept)",
                        provenance: .read)
        case (_, "chosen"):
            return Step(topic: "Identity", answer: "\(n) copies of one photograph",
                        why: "You looked at these and said they are the same photograph. \(kept)",
                        provenance: .chosen)
        case (_, "same recording"):
            return Step(topic: "Identity", answer: "\(n) copies of one recording",
                        why: "Same duration, and frames sampled at 10%, 50% and 90% match. \(kept)",
                        provenance: .inferred)
        default:
            return Step(topic: "Identity", answer: "\(n) copies of one photograph",
                        why: "Their perceptual fingerprints are near-identical, they share a capture instant, and a pixel comparison at two resolutions agrees — so this is a re-encode, not a similar shot. \(kept)",
                        provenance: .inferred)
        }
    }

    static func time(_ a: Asset) -> Step {
        guard let r = a.resolution, let t = r.localTime else {
            return Step(topic: "When", answer: "Unknown",
                        why: "No copy carries a capture date, and none has a usable file date.",
                        provenance: .unknown)
        }
        if r.timeSource.hasSuffix(", shown in UTC") {
            let src = r.timeSource.replacingOccurrences(of: ", shown in UTC", with: "")
            return Step(topic: "When", answer: pretty(t) + " UTC",
                        why: "The \(src.lowercased()) records the exact instant, but nothing says which timezone it was taken in — so it is shown in UTC rather than given a zone that might be wrong. Its order against every other photograph is still exact.",
                        provenance: .read)
        }
        switch r.timeSource {
        case "you entered the day":
            return Step(topic: "When", answer: String(pretty(t).split(separator: ",").first ?? ""),
                        why: "No copy carries a capture date. You entered this day in Fill in; the time of day is not known, and a merged copy writes it as noon. Clear it there to take it back.",
                        provenance: .chosen)
        case "Takeout sidecar":
            return Step(topic: "When", answer: pretty(t),
                        why: "No copy carries a capture date inside the file. Google Takeout's sidecar records the instant it was taken; the local time follows from the timezone below.",
                        provenance: .read)
        case "video container":
            return Step(topic: "When", answer: pretty(t),
                        why: "The video container records its creation instant in UTC; the local time follows from the timezone below.",
                        provenance: .read)
        case "Pixel filename (UTC)", "epoch filename (UTC)":
            return Step(topic: "When", answer: pretty(t),
                        why: "The filename is an absolute instant — \(r.timeSource == "Pixel filename (UTC)" ? "Google Pixel names files in UTC" : "the number is seconds since 1970") — and the local time follows from the timezone below.",
                        provenance: .read)
        case "filename":
            return Step(topic: "When", answer: pretty(t),
                        why: "No capture date inside any copy. The filename carries a date and time, which phones write as the local clock.",
                        provenance: .read)
        case "WhatsApp filename (date only)":
            return Step(topic: "When", answer: String(pretty(t).split(separator: ",").first ?? ""),
                        why: "No capture date inside any copy. The WhatsApp filename carries the day only; the time of day is unknown.",
                        provenance: .inferred)
        default: break
        }
        if r.timeSource.hasPrefix("mtime") {
            return Step(topic: "When", answer: pretty(t),
                        why: "No copy carries a capture date. This is the file's modification time, which is often when it was copied or exported — not when it was taken.",
                        provenance: .inferred)
        }
        let claims = Set(a.files.compactMap(\.capturedAt))
        let from = a.files.first { $0.capturedAt == t }?.name ?? "the photograph"
        if claims.count > 1 {
            let others = claims.subtracting([t]).sorted().map(pretty).joined(separator: ", ")
            return Step(topic: "When", answer: pretty(t),
                        why: "The copies disagree — \(from) says \(pretty(t)), others say \(others). The earliest is used: a later date is usually an export or edit, never an earlier capture.",
                        provenance: .read)
        }
        return Step(topic: "When", answer: pretty(t),
                    why: "Read from the capture date recorded in \(from).", provenance: .read)
    }

    static func zone(_ a: Asset) -> Step {
        guard let r = a.resolution else {
            return Step(topic: "Timezone", answer: "Unknown", why: "Not resolved yet.", provenance: .unknown)
        }
        let o = r.utcOffset ?? "—"
        if r.zoneSource.hasPrefix("clock + ") {
            let src = r.zoneSource.dropFirst("clock + ".count).replacingOccurrences(of: " instant", with: "")
            return Step(topic: "Timezone", answer: o,
                        why: "Worked out exactly: the photograph records its local clock, and the \(src.lowercased()) records the same moment as an absolute instant. The difference between them is the offset.",
                        provenance: .read)
        }
        switch r.zoneSource {
        case "you corrected it":
            return Step(topic: "Timezone", answer: o,
                        why: "You corrected this. The file recorded the right instant under the wrong offset — contradicted by photographs taken at the same place and time — so the instant was kept and the local time follows from \(o).",
                        provenance: .chosen)
        case "nearest photo in time":
            return Step(topic: "Timezone", answer: o,
                        why: "This photograph's time is an absolute instant with no local clock. The nearest photograph in time that records its own offset, within two days, uses \(o).",
                        provenance: .inferred)
        case "tag":
            return Step(topic: "Timezone", answer: o,
                        why: "The photograph records its own offset from UTC.", provenance: .read)
        case "you chose it":
            return Step(topic: "Timezone", answer: o,
                        why: "No copy records an offset. You chose \(o) for this day in Dates & places; it can be taken back there.",
                        provenance: .chosen)
        case "from a nearby photo's own offset":
            return Step(topic: "Timezone", answer: o,
                        why: "No copy records an offset. Photographs taken within 300 km of here that do record one use \(o), preferring the same month so daylight saving matches.",
                        provenance: .inferred)
        case "nearest dated photo":
            return Step(topic: "Timezone", answer: o,
                        why: "No copy records an offset and nothing nearby does. A photograph from within two days records \(o); the zone is assumed not to have changed.",
                        provenance: .inferred)
        default:
            return Step(topic: "Timezone", answer: "Unknown",
                        why: "No copy records an offset and nothing close enough does. Without one this time cannot be ordered against photographs from other zones.",
                        provenance: .unknown)
        }
    }

    static func place(_ a: Asset, _ p: Resolver.Params) -> Step {
        guard let r = a.resolution, let la = r.lat, let lo = r.lon else {
            let hadFix = a.files.contains { $0.lat != nil }
            return Step(topic: "Where", answer: "Unknown",
                        why: hadFix ? "Not resolved yet."
                                    : "No copy has GPS, and no photograph with GPS was taken close enough in time on the same day.",
                        provenance: .unknown)
        }
        let at = placeLabel(la, lo)
        let src = r.placeSource
        if src == "measured" {
            let from = a.files.first { $0.lat != nil }?.name ?? "the photograph"
            return Step(topic: "Where", answer: at, why: "GPS recorded in \(from): \(prettyPlace(la, lo)).", provenance: .read)
        }
        if src == "you entered it" {
            return Step(topic: "Where", answer: at,
                        why: "No copy has GPS. You entered this place in Fill in; clear it there to take it back.",
                        provenance: .chosen)
        }
        if src == "you confirmed it" {
            return Step(topic: "Where", answer: at,
                        why: "No copy has GPS. The app worked this place out and you accepted it; clear it in Fill in to take it back.",
                        provenance: .chosen)
        }
        if src.hasPrefix("your rule: ") {
            return Step(topic: "Where", answer: at,
                        why: "No copy has GPS and no photograph nearby in time could place it. You set a rule — “\(src.dropFirst("your rule: ".count))” — and this photograph falls under it. Remove the rule in Dates & places to take it back.",
                        provenance: .chosen)
        }
        if src == "sidecar GPS" {
            return Step(topic: "Where", answer: at,
                        why: "No GPS inside the file. Google Takeout's sidecar carries the camera's fix.",
                        provenance: .read)
        }
        if src == "same folder, same place" {
            let folder = a.files.compactMap(\.album).first.map { "“\($0)”" } ?? "its folder"
            return Step(topic: "Where", answer: at,
                        why: "No copy has GPS, and nothing on the same day is close enough in time. Every photograph in \(folder) that does have GPS lies within \(Int(p.dayRadiusKM)) km of the others, so the folder names one place and this one is placed at its centre.",
                        provenance: .inferred)
        }
        if src == "same day, same place" {
            return Step(topic: "Where", answer: at,
                        why: "No copy has GPS. Every photograph with GPS from the same day lies within \(Int(p.dayRadiusKM)) km of the others, so this one is placed at their centre.",
                        provenance: .inferred)
        }
        if src.hasPrefix("nearest fix") {
            let minutes = src.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return Step(topic: "Where", answer: at,
                        why: "No copy has GPS. The nearest photograph with GPS on the same day was taken \(minutes) away, inside the \(Int(p.travelMinutes))-minute travel bound; its position is used.",
                        provenance: .inferred)
        }
        return Step(topic: "Where", answer: at, why: src, provenance: .inferred)
    }

    // MARK: reading the catalog

    static func load(_ c: Catalog, cluster: Int) -> Asset? {
        var method = "single"
        var res: Resolver.Resolved? = nil
        guard let st = try? c.prepare("""
            SELECT c.method, r.local_time, r.time_source, r.utc_offset, r.zone_source,
                   r.lat, r.lon, r.place_source, r.instant, r.cluster_id
            FROM cluster c LEFT JOIN resolution r ON r.cluster_id = c.id WHERE c.id = ?;
            """) else { return nil }
        st.bind(1, cluster)
        guard st.step() else { st.finalize(); return nil }
        method = st.text(0) ?? "single"
        if !st.isNull(9) {
            res = Resolver.Resolved(
                clusterID: cluster, localTime: st.text(1), timeSource: st.text(2) ?? "none",
                utcOffset: st.text(3), zoneSource: st.text(4) ?? "none",
                lat: st.isNull(5) ? nil : st.double(5), lon: st.isNull(6) ? nil : st.double(6),
                placeSource: st.text(7) ?? "none", instant: st.isNull(8) ? nil : st.double(8))
        }
        st.finalize()

        var files: [FileClaim] = []
        if let fs = try? c.prepare("""
            SELECT f.id, f.path, m.role, m.reason, f.captured_at, f.utc_offset, f.lat, f.lon,
                   f.model, f.size, f.width, f.height,
                   f.utc_instant, f.utc_source, f.name_local, f.name_rule, f.sidecar, f.album, f.name_utc
            FROM member m JOIN file f ON f.id = m.file_id WHERE m.cluster_id = ?
            ORDER BY CASE m.role WHEN 'canonical' THEN 0 ELSE 1 END, f.size DESC;
            """) {
            fs.bind(1, cluster)
            while fs.step() {
                var fc = FileClaim(
                    id: fs.int(0), path: fs.text(1) ?? "", role: fs.text(2) ?? "",
                    reason: fs.text(3), capturedAt: fs.text(4), utcOffset: fs.text(5),
                    lat: fs.isNull(6) ? nil : fs.double(6), lon: fs.isNull(7) ? nil : fs.double(7),
                    model: fs.text(8), bytes: fs.int(9), width: fs.int(10), height: fs.int(11))
                fc.utcInstant = fs.isNull(12) ? (fs.isNull(18) ? nil : fs.double(18)) : fs.double(12)
                fc.utcSource = fs.isNull(12) ? (fs.isNull(18) ? nil : fs.text(15)) : fs.text(13)
                fc.nameClock = fs.text(14); fc.nameRule = fs.text(15)
                fc.sidecar = fs.text(16).map { ($0 as NSString).lastPathComponent }
                fc.album = fs.text(17)
                files.append(fc)
            }
            fs.finalize()
        }
        return Asset(clusterID: cluster, method: method, files: files, resolution: res)
    }

    struct Row: Identifiable {
        let id: Int               // cluster id
        let localTime: String?
        let timeSource: String
        let zoneSource: String
        let placeSource: String
        let copies: Int
        let path: String
    }

    enum Filter: String, CaseIterable, Identifiable {
        case inferred = "Estimated", noZone = "No timezone", noPlace = "No place",
             duplicates = "Duplicates", live = "Live Photos", chosen = "Chosen by you", all = "Everything"
        var id: String { rawValue }
        var sql: String {
            switch self {
            case .inferred:   return "(r.time_source LIKE 'mtime%' OR r.time_source LIKE '%date only%' OR (r.zone_source NOT IN ('tag','none','you chose it') AND r.zone_source NOT LIKE 'clock + %') OR r.place_source NOT IN ('measured','sidecar GPS','none'))"
            case .noZone:     return "r.utc_offset IS NULL"
            case .noPlace:    return "r.lat IS NULL"
            case .duplicates: return "EXISTS (SELECT 1 FROM member d WHERE d.cluster_id = c.id AND d.role = 'duplicate')"
            case .live:       return "EXISTS (SELECT 1 FROM member d WHERE d.cluster_id = c.id AND d.role = 'companion')"
            case .chosen:     return "r.zone_source IN ('you chose it','you corrected it')"
            case .all:        return "1"
            }
        }
    }

    static func list(_ c: Catalog, _ filter: Filter, limit: Int = 1500) -> (rows: [Row], total: Int) {
        let base = """
            FROM cluster c JOIN resolution r ON r.cluster_id = c.id
            JOIN member m ON m.cluster_id = c.id AND m.role = 'canonical'
            JOIN file f ON f.id = m.file_id
            WHERE \(filter.sql)
            """
        let total = c.scalarInt("SELECT COUNT(*) \(base);")
        var rows: [Row] = []
        if let st = try? c.prepare("""
            SELECT c.id, r.local_time, r.time_source, r.zone_source, r.place_source, (SELECT COUNT(*) FROM member x WHERE x.cluster_id = c.id AND x.role IN ('canonical','duplicate')), f.path
            \(base) ORDER BY r.local_time DESC LIMIT \(limit);
            """) {
            while st.step() {
                rows.append(Row(id: st.int(0), localTime: st.text(1),
                                timeSource: st.text(2) ?? "none", zoneSource: st.text(3) ?? "none",
                                placeSource: st.text(4) ?? "none", copies: st.int(5),
                                path: st.text(6) ?? ""))
            }
            st.finalize()
        }
        return (rows, total)
    }
}
