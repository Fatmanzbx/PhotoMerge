import Foundation

/// Formatting shared by the UI and by the explanations in `Decisions`. Foundation
/// only, so the headless tests compile it too.

func byteString(_ n: Int) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file
    return f.string(fromByteCount: Int64(n))
}

/// "2021:03:07 14:22:31" → "7 Mar 2021, 14:22"
func pretty(_ s: String) -> String {
    guard let p = Resolver.parse(s) else { return s }
    let months = ["", "Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
    let mo = (1...12).contains(p.mo) ? months[p.mo] : "?"
    return String(format: "%d %@ %d, %02d:%02d", p.d, mo, p.y, p.h, p.mi)
}

/// Coordinates as a person reads them, not as a database stores them.
func prettyPlace(_ lat: Double, _ lon: Double) -> String {
    String(format: "%.4f°%@ %.4f°%@", abs(lat), lat >= 0 ? "N" : "S",
           abs(lon), lon >= 0 ? "E" : "W")
}

/// Evidence read straight off the file, versus evidence the app worked out.
func isInferred(_ source: String?) -> Bool {
    guard let s = source, !s.isEmpty, s != "none" else { return false }
    let read = ["exif", "tag", "measured", "sidecar GPS", "Takeout sidecar", "video container",
                "Pixel filename (UTC)", "epoch filename (UTC)", "filename", "you chose it", "you corrected it",
                "you entered it", "you entered the day", "you confirmed it"]
    // "exif · tag", "exif · clock + Takeout sidecar instant", …: read if every part is
    return !s.components(separatedBy: " · ").allSatisfy { part in
        read.contains(part) || part.hasPrefix("clock + ") || part.hasPrefix("your rule: ")
    }
}

/// Diagnostics to stderr when launched with PM_DEBUG set, e.g.
/// `open --env PM_DEBUG=1 --stderr /tmp/pm.log PhotoMerge.app`. Silent otherwise.
func debugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["PM_DEBUG"] != nil else { return }
    FileHandle.standardError.write((message() + "\n").data(using: .utf8)!)
}

/// Fault injection for the crash tests (Tests/crash_test.sh): `PM_CRASH=<point>:<n>`
/// kills the process outright the n-th time `point` is reached, as a power cut would.
/// Unset in normal use, when this is one dictionary lookup.
enum Crash {
    private static let spec: (String, Int)? = {
        guard let v = ProcessInfo.processInfo.environment["PM_CRASH"], let i = v.lastIndex(of: ":"),
              let n = Int(v[v.index(after: i)...]) else { return nil }
        return (String(v[..<i]), n)
    }()
    private static var hits = 0
    private static let lock = NSLock()
    static func point(_ name: String) {
        guard let (p, n) = spec, p == name else { return }
        lock.lock(); hits += 1; let h = hits; lock.unlock()
        if h >= n { kill(getpid(), SIGKILL) }
    }
}

/// A place as a person says it — "Lisbon, Portugal" — from the offline gazetteer,
/// falling back to coordinates where no town is near enough to name honestly.
func placeLabel(_ lat: Double, _ lon: Double) -> String {
    Gazetteer.describe(lat, lon) ?? prettyPlace(lat, lon)
}
