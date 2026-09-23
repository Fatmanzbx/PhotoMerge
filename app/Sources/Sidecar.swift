import Foundation

/// Google Takeout keeps capture time and GPS in `*.supplemental-metadata.json`
/// beside each file, often *instead of* in it. Ported from the Python CLI, whose
/// cascade matched 12,610 of 12,610 files on a real export (BUILDLOG §2.1).
///
/// Two `(n)` collision conventions coexist in one export:
///
///     IMG_0088 (1).jpeg  ->  IMG_0088 (1).jpeg.supplemental-metadata.json
///     IMG_0899(1).HEIC   ->  IMG_0899.HEIC.supplemental-metadata(1).json
///
/// and extension case need not agree, so every lookup is case-folded.
enum Sidecar {

    struct Facts: Equatable {
        var takenUTC: Double?        // photoTakenTime — an instant, not a wall clock
        var lat: Double?, lon: Double?
        var title: String?           // the name the file had before export
    }

    static let supplemental = ".supplemental-metadata"
    static let editSuffixes = ["-EFFECTS-edited", "-edited", "-EFFECTS"]

    /// A case-folded listing per directory, built once: sidecar lookup is thousands
    /// of near-misses, and stat-ing each would dominate the scan.
    final class Index: @unchecked Sendable {
        private var cache: [String: [String: String]] = [:]
        private let lock = NSLock()
        func names(_ dir: String) -> [String: String] {
            lock.lock(); defer { lock.unlock() }
            if let hit = cache[dir] { return hit }
            var idx: [String: String] = [:]
            for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                idx[n.lowercased()] = n
            }
            cache[dir] = idx
            return idx
        }
        func get(_ dir: String, _ name: String) -> String? {
            names(dir)[name.lowercased()].map { (dir as NSString).appendingPathComponent($0) }
        }
        func first(_ dir: String, prefix: String, suffix: String) -> String? {
            let (p, s) = (prefix.lowercased(), suffix.lowercased())
            return names(dir).filter { $0.key.hasPrefix(p) && $0.key.hasSuffix(s) }
                .sorted { $0.key < $1.key }.first
                .map { (dir as NSString).appendingPathComponent($0.value) }
        }
    }

    /// The sidecar for one media file, and which rule of the cascade found it.
    static func find(_ path: String, _ index: Index) -> (path: String, rule: String)? {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension

        // 1. the common shape, and the bare `.json` fallback
        if let h = index.get(dir, name + supplemental + ".json") { return (h, "exact") }
        if let h = index.get(dir, name + ".json") { return (h, "bare") }
        // 2. a supplemental suffix truncated to fit a filename limit
        if let h = index.first(dir, prefix: name + ".supplemental", suffix: ".json") { return (h, "truncated") }
        // 3. the collision number carried on the sidecar instead of the media
        if let m = stem.range(of: #"\((\d+)\)$"#, options: .regularExpression) {
            let n = stem[m].dropFirst().dropLast()
            let base = String(stem[..<m.lowerBound]).trimmingCharacters(in: .whitespaces)
            for c in ["\(base).\(ext)\(supplemental)(\(n)).json", "\(base).\(ext)(\(n)).json"] {
                if let h = index.get(dir, c) { return (h, "collision") }
            }
        }
        // 4. no extension, or a sidecar written against a different one
        if let h = index.first(dir, prefix: stem + ".", suffix: ".json"), !h.hasSuffix(name) { return (h, "stem") }
        // 5. motion photo still: X.MP.jpg carries another extension in its stem
        if stem.lowercased().hasSuffix(".mp") {
            let base = String(stem.dropLast(3))
            if let h = index.first(dir, prefix: base + ".", suffix: ".json") { return (h, "motion photo") }
        }
        // 6. an edit inherits from its origin — Google ships no sidecar for edits
        for s in editSuffixes where stem.lowercased().hasSuffix(s.lowercased()) {
            let origin = String(stem.dropLast(s.count))
            if let h = index.first(dir, prefix: origin + ".", suffix: ".json") { return (h, "edit of origin") }
        }
        return nil
    }

    static func parse(_ data: Data) -> Facts? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var f = Facts()
        if let t = obj["photoTakenTime"] as? [String: Any], let s = t["timestamp"] {
            let v = (s as? String).flatMap(Double.init) ?? (s as? Double)
            if let v, v > 0 { f.takenUTC = v }
        }
        // geoDataExif is the camera's own fix; geoData may be a pin dropped by hand.
        // Google writes (0, 0) for "no location" — only that exact pair is absent.
        for key in ["geoDataExif", "geoData"] {
            guard let g = obj[key] as? [String: Any],
                  let la = (g["latitude"] as? NSNumber)?.doubleValue,
                  let lo = (g["longitude"] as? NSNumber)?.doubleValue,
                  !(la == 0 && lo == 0) else { continue }
            f.lat = la; f.lon = lo
            break
        }
        f.title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespaces)
        return f
    }
}
