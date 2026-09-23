import Foundation

/// BK-tree over Hamming distance. Replaces the N² comparison matrix: at 100k assets
/// that would be 5 billion pairs.
///
/// Multi-valued on purpose — many files legitimately share one dHash (a burst, a
/// wallpaper pack), and a duplicate key must not become a duplicate node.
final class BKTree {
    private var keys: [UInt64] = []
    private var values: [[Int]] = []
    private var children: [[Int: Int]] = []
    private var root: Int?

    var count: Int { values.reduce(0) { $0 + $1.count } }
    var nodes: Int { keys.count }

    @inline(__always) static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    func add(_ key: UInt64, _ value: Int) {
        guard var cur = root else {
            keys.append(key); values.append([value]); children.append([:]); root = 0
            return
        }
        while true {
            let d = BKTree.distance(key, keys[cur])
            if d == 0 { values[cur].append(value); return }
            if let next = children[cur][d] { cur = next; continue }
            keys.append(key); values.append([value]); children.append([:])
            children[cur][d] = keys.count - 1
            return
        }
    }

    /// Every stored value whose key is within `radius` of `key`.
    func query(_ key: UInt64, radius: Int) -> [Int] {
        guard let root else { return [] }
        var out: [Int] = []
        var stack = [root]
        while let node = stack.popLast() {
            let d = BKTree.distance(key, keys[node])
            if d <= radius { out.append(contentsOf: values[node]) }
            let lo = d - radius, hi = d + radius
            for (edge, child) in children[node] where edge >= lo && edge <= hi {
                stack.append(child)
            }
        }
        return out
    }
}

/// Union-find, so a cluster is a connected component rather than a chain of pairs.
struct DisjointSet {
    private var parent: [Int]
    init(_ n: Int) { parent = Array(0..<n) }
    mutating func find(_ x: Int) -> Int {
        var r = x
        while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
        return r
    }
    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[rb] = ra }
    }
}
