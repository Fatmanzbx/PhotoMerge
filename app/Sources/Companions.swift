import Foundation

/// Live Photos and motion photos: a still and its short clip are one photograph,
/// not two (PLAN §7.1, M4).
///
/// Three rules, each from a real failure (BUILDLOG §2.11):
///  1. Apple's `ContentIdentifier` decides. It is written into both halves and is
///     the camera's own assertion of which movie belongs to which still.
///  2. A still has **at most one** companion. A long unrelated video that merely
///     shared a name was once attached beside the real clip — and took the name.
///  3. A name match is allowed only when neither side says otherwise: the movie
///     carries no identifier of its own, and it is short enough to be a clip.
enum Companions {

    struct Side {
        let group: Int                  // index into the stills' or movies' groups
        let contentIDs: Set<String>
        let stems: Set<String>          // directory + normalised stem, per member
        var duration: Double = 0
    }

    /// Longest clip a name alone may attach. Live Photos run ~1.5–3 s; Google's
    /// motion photos up to ~3 s; 6 s leaves room without admitting real videos.
    static let maxClipSeconds = 6.0

    /// "IMG_1234.HEIC" and "IMG_1234.MOV"; "PXL_1.MP.jpg" and "PXL_1.MP";
    /// "UUID.heic" and "UUID_3.mov" (a Photos library's own naming).
    static func stem(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent.lowercased()
        var s = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        if s.hasSuffix(".mp") { s = String(s.dropLast(3)) }
        if s.hasSuffix("_3") { s = String(s.dropLast(2)) }
        return dir + "/" + s
    }

    /// still group → (movie group, rule)
    static func pair(stills: [Side], movies: [Side]) -> [Int: (movie: Int, rule: String)] {
        var out: [Int: (Int, String)] = [:]
        var taken = Set<Int>()

        // 1. content identifier
        var byID: [String: Int] = [:]
        for s in stills { for id in s.contentIDs { byID[id] = s.group } }
        for m in movies.sorted(by: { $0.group < $1.group }) {
            let hits = Set(m.contentIDs.compactMap { byID[$0] })
            guard hits.count == 1, let s = hits.first, out[s] == nil else { continue }
            out[s] = (m.group, "content identifier"); taken.insert(m.group)
        }

        // 3. by name — only where no identifier says otherwise
        var byStem: [String: Int] = [:]
        for s in stills where out[s.group] == nil && s.contentIDs.isEmpty {
            for st in s.stems { byStem[st] = s.group }
        }
        for m in movies.sorted(by: { $0.duration < $1.duration })
        where !taken.contains(m.group) && m.contentIDs.isEmpty && m.duration > 0 && m.duration <= maxClipSeconds {
            let hits = Set(m.stems.compactMap { byStem[$0] })
            guard hits.count == 1, let s = hits.first, out[s] == nil else { continue }
            out[s] = (m.group, "same name, short clip"); taken.insert(m.group)
        }
        return out
    }
}
