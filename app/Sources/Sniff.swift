import Foundation

/// INHERITED §2.2 — the extension lies. Type comes from magic bytes, and ISO-BMFF
/// `ftyp` brands are what separate HEIC from MP4: both are BMFF containers, so
/// container detection alone is not enough.
enum Sniff {
    enum Kind: String { case image, video, other }

    struct Result { let kind: Kind; let mime: String }

    /// Brands that mean "still image" even though the container is the same as video.
    private static let imageBrands: Set<String> = [
        "heic", "heix", "heim", "heis", "hevc", "hevx",   // HEIF image
        "mif1", "msf1", "miaf",                            // generic HEIF
        "avif", "avis",                                    // AVIF
    ]
    private static let videoBrands: Set<String> = [
        "qt  ", "isom", "iso2", "mp41", "mp42", "mp4v", "M4V ", "M4A ",
        "avc1", "dash", "3gp4", "3gp5", "hevd",
    ]

    static func sniff(_ url: URL) -> Result? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 32), head.count >= 12 else { return nil }
        let b = [UInt8](head)

        // JPEG
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .init(kind: .image, mime: "image/jpeg") }
        // PNG
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .init(kind: .image, mime: "image/png") }
        // GIF
        if b.starts(with: Array("GIF8".utf8)) { return .init(kind: .image, mime: "image/gif") }
        // TIFF (and most RAW)
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return .init(kind: .image, mime: "image/tiff")
        }
        // WebP:  RIFF ???? WEBP
        if b.starts(with: Array("RIFF".utf8)), b.count >= 12,
           Array(b[8..<12]) == Array("WEBP".utf8) {
            return .init(kind: .image, mime: "image/webp")
        }
        // ISO-BMFF: ....ftypBRND
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) {
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            if imageBrands.contains(brand) { return .init(kind: .image, mime: "image/heic") }
            if videoBrands.contains(brand) { return .init(kind: .video, mime: "video/mp4") }
            // unknown brand in a BMFF container: treat as video, the safer default —
            // an unplayable image is recoverable, a silently-skipped video is not
            return .init(kind: .video, mime: "video/mp4")
        }
        return nil
    }
}
