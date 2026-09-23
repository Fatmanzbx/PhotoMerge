import Foundation

/// Dates hiding in filenames and folder names. Weak evidence, but far better than
/// a file's modification time, which is when it was copied.
///
/// Whether a pattern is a **wall clock** or a **UTC instant** is the whole point:
/// Google Pixel names files in UTC (`PXL_…`), while phones naming `IMG_…` use the
/// local clock. Measured against 4,320 Takeout sidecars that record the true
/// instant: 3,393 of 3,395 Pixel names matched UTC to the second; `IMG_` names sat
/// at −7, −8, +8, −5… hours from it. The Python CLI treated Pixel names as local.
enum Names {

    enum Claim: Equatable {
        case wall(String, rule: String)       // "YYYY:MM:DD HH:MM:SS", no zone
        case utc(Double, rule: String)        // seconds since epoch
    }

    static let minYear = 1995

    static func claim(_ filename: String) -> Claim? {
        let name = (filename as NSString).deletingPathExtension
        let maxYear = Calendar(identifier: .gregorian).component(.year, from: Date()) + 1

        // PXL_20250720_161254963 — Google Pixel, UTC
        if let m = match(name, #"^PXL_(\d{8})_(\d{6})"#),
           let s = wall(m[0] + m[1], maxYear) {
            return epochUTC(s).map { .utc($0, rule: "Pixel filename (UTC)") }
        }
        // IMG_20240101_120000, VID_…, 20240101_120000 — local wall clock
        if let m = match(name, #"(?:^|[^0-9])(20\d{6})[_-](\d{6})(?:\d{3})?(?:[^0-9]|$)"#),
           let s = wall(m[0] + m[1], maxYear) {
            return .wall(s, rule: "filename")
        }
        // Screenshot_2019-01-01-12-00-00, "Screenshot 2024-01-01 at 12.00.00"
        if let m = match(name, #"((?:19|20)\d{2})-(\d{2})-(\d{2})(?:[ _-]|\s+at\s+)(\d{2})[.:-](\d{2})[.:-](\d{2})"#),
           let s = wall(m.joined(), maxYear) {
            return .wall(s, rule: "filename")
        }
        // IMG-20240101-WA0001 — WhatsApp, the date only
        if let m = match(name, #"(?:^|[^0-9])(20\d{6})-WA\d+"#),
           let s = wall(m[0] + "000000", maxYear) {
            return .wall(s, rule: "WhatsApp filename (date only)")
        }
        // mmexport1500000000000, 1500000000000, wx_camera_1500000000 — epoch, UTC
        if let m = match(name, #"(?:^|[^0-9])(1\d{12}|1\d{9})(?:[^0-9]|$)"#),
           let v = Double(m[0]) {
            let t = m[0].count == 13 ? v / 1000 : v
            let y = Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: t))
            if y >= minYear && y <= maxYear { return .utc(t, rule: "epoch filename (UTC)") }
        }
        return nil
    }

    /// "Photos from 2019" — Takeout's year folders. Anything else that is not a
    /// Takeout wrapper is an album name: a trip, an event, sometimes a place.
    static func folder(_ relPath: String) -> (year: Int?, album: String?) {
        var year: Int? = nil, album: String? = nil
        let parts = (relPath as NSString).pathComponents.dropLast()
        for part in parts {
            if let m = match(part, #"^Photos from ((?:19|20)\d{2})$"#) { year = Int(m[0]) }
            else if !isStorage(part) { album = part }
        }
        return (year, album)
    }

    /// Folders that organise storage rather than meaning: Takeout's wrappers, a
    /// Photos library's `0`…`F` shards, a camera's `DCIM/100APPLE`, dates.
    static let storageNames: Set<String> = [
        "takeout", "google photos", "dcim", "camera", "pictures", "photos", "originals",
        "masters", "resources", "derivatives", "renders", "screenshots", "downloads",
        "whatsapp images", "whatsapp video", "icloud photos", "export", "exports", "images",
        "videos", "movies", "new folder", "untitled folder", "/", ".",
    ]

    static func isStorage(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        // short Latin names are shards ("F", "0A"); short CJK names are places (東京)
        if (n.count <= 2 && n.allSatisfy(\.isASCII)) || storageNames.contains(n) || n.hasSuffix(".photoslibrary") { return true }
        if match(n, #"^[0-9a-f-]+$"#) != nil { return true }                 // hex shards, uuids, numbers
        if match(n, #"^\d{3}[a-z_]{2,}"#) != nil { return true }             // 100APPLE, 101_PANA
        if match(n, #"^(19|20)\d{2}([-_ .]?\d{2}){0,2}$"#) != nil { return true }  // 2019, 2019-07, 2019_07_14
        return false
    }

    // MARK: helpers

    private static func match(_ s: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }

    /// 14 digits → "YYYY:MM:DD HH:MM:SS", or nil if it is not a real date and time.
    private static func wall(_ digits: String, _ maxYear: Int) -> String? {
        let d = Array(digits.filter(\.isNumber))
        guard d.count >= 14 else { return nil }
        func n(_ a: Int, _ b: Int) -> Int { Int(String(d[a..<b])) ?? -1 }
        let (y, mo, dd, h, mi, s) = (n(0, 4), n(4, 6), n(6, 8), n(8, 10), n(10, 12), n(12, 14))
        guard (minYear...maxYear).contains(y), (1...12).contains(mo), (1...31).contains(dd),
              (0...23).contains(h), (0...59).contains(mi), (0...60).contains(s) else { return nil }
        return String(format: "%04d:%02d:%02d %02d:%02d:%02d", y, mo, dd, h, mi, s)
    }

    private static func epochUTC(_ s: String) -> Double? { Resolver.epoch(s, "+00:00") }
}
