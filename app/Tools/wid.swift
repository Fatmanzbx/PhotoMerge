// Prints the window id of PhotoMerge's largest on-screen window, for screenshots.
// Lives in the repo rather than /tmp: the OS cleans /tmp, and a missing helper
// looks exactly like a crashed app — which cost real time once.
import CoreGraphics
import Foundation

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                      kCGNullWindowID) as? [[String: Any]] ?? []
var best = (num: 0, area: 0.0)
for w in list where (w[kCGWindowOwnerName as String] as? String) == "PhotoMerge" {
    guard let n = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: Any],
          let h = b["Height"] as? Double, let wd = b["Width"] as? Double else { continue }
    if h * wd > best.area { best = (n, h * wd) }
}
if best.num != 0 {
    print(best.num)
} else {
    FileHandle.standardError.write("no on-screen PhotoMerge window\n".data(using: .utf8)!)
    exit(1)
}
