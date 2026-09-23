import Foundation
import ImageIO
import CoreGraphics
import CryptoKit

/// Per-file facts. Everything the identity cascade and the resolver need.
struct Facts {
    var sha256: String
    /// SHA-256 of the 64x64 orientation-normalised luminance grid. Strong enough to
    /// mean "the same image content"; the 9x8 dHash grid was tried first and is far
    /// too coarse to support that claim — a 50% resize produces an identical one.
    var pixelHash: String?
    var dhash64: UInt64?
    var width: Int
    var height: Int
    var capturedAt: String?     // "YYYY:MM:DD HH:MM:SS" as recorded
    var utcOffset: String?      // "+08:00" if the file says so
    var lat: Double?
    var lon: Double?
    var make: String?
    var model: String?
    /// 64x64 grayscale, orientation-normalised. 16x16 was tried first and was far
    /// too coarse: nine pairs of genuinely different photographs all scored under
    /// the confirm threshold because detail averages away at that size.
    var thumb: Data?
    /// Exposure value, from ISO, shutter and aperture. Exposure settings are a light
    /// meter: a day of outdoor photography traces a brightness curve whose plateau
    /// straddles local solar noon, which is enough to estimate a timezone with no
    /// other photo located (PLAN §7.4).
    var ev: Double?
    /// Video only.
    var duration: Double?
    var frames: Data?
    /// An absolute instant, when the file records one (a video container).
    var utcInstant: Double?
    /// Apple's assertion of which still and which movie make one Live Photo — the
    /// only reliable pairing (BUILDLOG §2.11). Filenames are not.
    var contentID: String?
    /// "embedded" for a Google Motion Photo: a JPEG carrying its clip inside.
    var motion: String?
}

enum Extractor {

    /// A Google Motion Photo announces its embedded clip in XMP near the start of
    /// the file (`GCamera:MicroVideo`, `GCamera:MotionPhoto`, or a Container
    /// directory with a MotionPhoto item). Reading 256 KB is enough and cheap.
    static func motionMarker(_ data: Data) -> String? {
        // A positive flag only: an edited export keeps `MotionPhoto="0"` after the
        // clip itself has been stripped.
        let head = data.prefix(256 * 1024)
        for marker in [#"MotionPhoto="1""#, #"MicroVideo="1""#, "MotionPhoto>1<", "MicroVideo>1<",
                       #"Semantic="MotionPhoto""#] {
            if head.range(of: Data(marker.utf8)) != nil { return "embedded" }
        }
        return nil
    }
    /// Reduce to a 9x8 grayscale grid once, and derive both hashes from it.
    /// `kCGImageSourceCreateThumbnailWithTransform` applies the EXIF orientation,
    /// so a rotated copy of the same photo hashes the same.
    /// One decode, two products: the 9x8 grid for dHash and a 64x64 for verification.
    private static func grids(_ url: URL) -> (dh: [UInt8], thumb: [UInt8])? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        func gray(_ w: Int, _ h: Int) -> [UInt8]? {
            var buf = [UInt8](repeating: 0, count: w * h)
            guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        guard let d = gray(9, 8), let t = gray(64, 64) else { return nil }
        return (d, t)
    }

    private static func dhash(_ g: [UInt8]) -> UInt64 {
        var bits: UInt64 = 0
        var i = 0
        for row in 0..<8 {
            for col in 0..<8 {
                if g[row * 9 + col] < g[row * 9 + col + 1] { bits |= (1 << UInt64(i)) }
                i += 1
            }
        }
        return bits
    }

    /// The content hash the catalog stores, for any bytes.
    static func sha(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    private static func hex(_ d: some Sequence<UInt8>) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    /// GPS in EXIF is degrees + a hemisphere ref; sign it here so the rest of the
    /// app never has to think about it.
    private static func coord(_ gps: [CFString: Any]) -> (Double, Double)? {
        guard let la = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lo = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let laRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
        let loRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
        let lat = laRef == "S" ? -la : la
        let lon = loRef == "W" ? -lo : lo
        // INHERITED: reject the null island — a 0,0 fix is a missing fix
        if abs(lat) < 0.0001 && abs(lon) < 0.0001 { return nil }
        return (lat, lon)
    }

    static func extract(_ url: URL, isImage: Bool) -> Facts? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if !isImage {
            // Video: duration + sampled frames, via AVFoundation (tier D).
            var f = Facts(sha256: hex(SHA256.hash(data: data)), pixelHash: nil, dhash64: nil,
                          width: 0, height: 0, capturedAt: nil, utcOffset: nil,
                          lat: nil, lon: nil, make: nil, model: nil)
            if let v = VideoExtractor.extract(url) {
                f.duration = v.duration
                f.frames = VideoExtractor.pack(v.frames)
                f.thumb = v.thumb
                f.capturedAt = v.capturedAt
                f.utcOffset = v.utcOffset
                f.utcInstant = v.utcInstant
                f.contentID = v.contentID
                f.lat = v.lat; f.lon = v.lon
                f.width = v.width; f.height = v.height
                f.dhash64 = v.frames.first
            }
            return f
        }
        var f = Facts(sha256: hex(SHA256.hash(data: data)), pixelHash: nil, dhash64: nil,
                      width: 0, height: 0, capturedAt: nil, utcOffset: nil,
                      lat: nil, lon: nil, make: nil, model: nil)

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return f }

        f.width  = p[kCGImagePropertyPixelWidth] as? Int ?? 0
        f.height = p[kCGImagePropertyPixelHeight] as? Int ?? 0

        if let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            f.make  = tiff[kCGImagePropertyTIFFMake] as? String
            f.model = tiff[kCGImagePropertyTIFFModel] as? String
        }
        if let apple = p[kCGImagePropertyMakerAppleDictionary] as? [String: Any],
           let cid = apple["17"] as? String, !cid.isEmpty {
            f.contentID = cid
        }
        f.motion = Extractor.motionMarker(data)
        if let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            f.capturedAt = exif[kCGImagePropertyExifDateTimeOriginal] as? String
                        ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
            f.utcOffset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
                       ?? exif[kCGImagePropertyExifOffsetTime] as? String
        }
        if let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let (lat, lon) = coord(gps) { f.lat = lat; f.lon = lon }

        if let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            // EV = log2(N^2 / t) - log2(ISO/100)
            let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
                   ?? (exif[kCGImagePropertyExifISOSpeedRatings] as? Int)
            if let t = exif[kCGImagePropertyExifExposureTime] as? Double,
               let n = exif[kCGImagePropertyExifFNumber] as? Double,
               let iso, t > 0, n > 0, iso > 0 {
                f.ev = log2(n * n / t) - log2(Double(iso) / 100)
            }
        }

        if isImage, let g = grids(url) {
            f.dhash64 = dhash(g.dh)
            f.pixelHash = String(hex(SHA256.hash(data: Data(g.thumb))).prefix(32))
            f.thumb = Data(g.thumb)
        }
        return f
    }
}
