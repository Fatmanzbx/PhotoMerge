import Foundation
import AVFoundation
import CoreGraphics
import CryptoKit

/// Video facts. A re-encoded video shares no bytes with its original, so identity
/// rests on duration plus sampled frames (INHERITED §5, tier D).
struct VideoFacts {
    var duration: Double
    /// dHash of three frames, at 10% / 50% / 90% of the duration.
    var frames: [UInt64]
    /// 64x64 grayscale of the middle frame, for the same slope verification the
    /// still cascade uses.
    var thumb: Data?
    /// Local wall clock and its offset, when the recorder wrote them (Apple's
    /// `com.apple.quicktime.creationdate`, "2021-04-14T08:00:00+0800").
    var capturedAt: String?
    var utcOffset: String?
    /// The container's own creation date. QuickTime defines it as UTC, so it is an
    /// instant — never a wall clock (INHERITED §2.7).
    var utcInstant: Double?
    var contentID: String?
    var lat: Double?
    var lon: Double?
    var width: Int
    var height: Int
}

enum VideoExtractor {

    /// Sampling near the very start or end is unreliable — many containers have a
    /// black or partial first frame — so the positions are pulled inward.
    static let positions: [Double] = [0.1, 0.5, 0.9]

    static func extract(_ url: URL) -> VideoFacts? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let dur = CMTimeGetSeconds(asset.duration)
        guard dur.isFinite, dur > 0 else { return nil }

        var v = VideoFacts(duration: dur, frames: [], thumb: nil,
                           capturedAt: nil, lat: nil, lon: nil, width: 0, height: 0)

        if let track = asset.tracks(withMediaType: .video).first {
            let size = track.naturalSize.applying(track.preferredTransform)
            v.width = Int(abs(size.width)); v.height = Int(abs(size.height))
        }

        // Apple's local date, with its offset, is the best a video offers.
        for item in asset.metadata where item.identifier?.rawValue == "mdta/com.apple.quicktime.creationdate"
                                      || (item.key as? String) == "com.apple.quicktime.creationdate" {
            if let str = item.stringValue, let (local, off) = VideoExtractor.localWithOffset(str) {
                v.capturedAt = local; v.utcOffset = off
            }
        }
        for item in asset.metadata where item.identifier?.rawValue == "mdta/com.apple.quicktime.content.identifier" {
            if let cid = item.stringValue, !cid.isEmpty { v.contentID = cid }
        }
        // The container's creation date is UTC by specification: an instant.
        for item in asset.commonMetadata where item.commonKey == .commonKeyCreationDate {
            if let d = item.dateValue { v.utcInstant = d.timeIntervalSince1970 }
        }
        // ISO-6709 location string, e.g. "+37.7858-122.4064+010.000/"
        for item in asset.metadata where item.key as? String == "com.apple.quicktime.location.ISO6709"
                                      || item.commonKey?.rawValue == "location" {
            if let s = item.stringValue, let (la, lo) = parseISO6709(s) { v.lat = la; v.lon = lo }
        }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true          // orientation-normalised
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: 256, height: 256)

        for (i, frac) in positions.enumerated() {
            let t = CMTime(seconds: max(0, min(dur - 0.05, dur * frac)), preferredTimescale: 600)
            guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { continue }
            guard let g = grid(cg, 9, 8) else { continue }
            v.frames.append(dhash(g))
            if i == 1, let t64 = grid(cg, 64, 64) { v.thumb = Data(t64) }
        }
        return v.frames.isEmpty ? nil : v
    }

    /// "2021-04-14T08:00:00+0800" → ("2021:04:14 08:00:00", "+08:00").
    static func localWithOffset(_ s: String) -> (String, String)? {
        guard let re = try? NSRegularExpression(
                pattern: #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?([+-])(\d{2}):?(\d{2})$"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let g = (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
        return ("\(g[0]):\(g[1]):\(g[2]) \(g[3]):\(g[4]):\(g[5])", "\(g[6])\(g[7]):\(g[8])")
    }

    static func parseISO6709(_ s: String) -> (Double, Double)? {
        // "+37.7858-122.4064+010.000/"  → signed decimal pairs
        var nums: [Double] = []
        var cur = ""
        for ch in s {
            if ch == "+" || ch == "-" {
                if let d = Double(cur) { nums.append(d) }
                cur = String(ch)
            } else if ch.isNumber || ch == "." {
                cur.append(ch)
            } else { break }
        }
        if let d = Double(cur) { nums.append(d) }
        guard nums.count >= 2 else { return nil }
        let (la, lo) = (nums[0], nums[1])
        if abs(la) < 0.0001 && abs(lo) < 0.0001 { return nil }   // null island
        return (la, lo)
    }

    private static func grid(_ cg: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private static func dhash(_ g: [UInt8]) -> UInt64 {
        var bits: UInt64 = 0, i = 0
        for row in 0..<8 { for col in 0..<8 {
            if g[row * 9 + col] < g[row * 9 + col + 1] { bits |= (1 << UInt64(i)) }
            i += 1
        } }
        return bits
    }

    /// Pack/unpack the frame hashes for the catalog.
    static func pack(_ hs: [UInt64]) -> Data {
        var d = Data(); for h in hs { withUnsafeBytes(of: h.bigEndian) { d.append(contentsOf: $0) } }
        return d
    }
    static func unpack(_ d: Data?) -> [UInt64] {
        guard let d, d.count % 8 == 0 else { return [] }
        return stride(from: 0, to: d.count, by: 8).map { i in
            d[i..<i+8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
    }
}
