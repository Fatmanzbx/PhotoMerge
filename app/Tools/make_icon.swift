// Draws the PhotoMerge icon and writes Resources/AppIcon.icns.
//   xcrun swift Tools/make_icon.swift
// Two photographs becoming one, with a check: merged, and verified.
import AppKit

func draw(_ side: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: side, height: side))
    img.lockFocus()
    let s = side / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS icon grid: an 824-pt squircle centred in 1024, with a soft shadow
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor(srgbRed: 0.10, green: 0.42, blue: 0.86, alpha: 1).setFill(); squircle.fill()
    ctx.restoreGState()
    squircle.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.62, blue: 0.95, alpha: 1),
                        NSColor(srgbRed: 0.09, green: 0.33, blue: 0.80, alpha: 1)])!
        .draw(in: body, angle: -90)

    func card(_ rect: CGRect, angle: CGFloat, sky: NSColor, hill: NSColor) {
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY); ctx.rotate(by: angle * .pi / 180)
        let r = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: 34 * s, yRadius: 34 * s).fill()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let inner = r.insetBy(dx: 26 * s, dy: 26 * s)
        let photo = NSBezierPath(roundedRect: inner, xRadius: 18 * s, yRadius: 18 * s)
        NSGraphicsContext.current!.saveGraphicsState(); photo.addClip()
        sky.setFill(); inner.fill()
        let hills = NSBezierPath()
        hills.move(to: CGPoint(x: inner.minX, y: inner.minY + inner.height * 0.28))
        hills.line(to: CGPoint(x: inner.minX + inner.width * 0.34, y: inner.minY + inner.height * 0.62))
        hills.line(to: CGPoint(x: inner.minX + inner.width * 0.56, y: inner.minY + inner.height * 0.40))
        hills.line(to: CGPoint(x: inner.minX + inner.width * 0.74, y: inner.minY + inner.height * 0.55))
        hills.line(to: CGPoint(x: inner.maxX, y: inner.minY + inner.height * 0.30))
        hills.line(to: CGPoint(x: inner.maxX, y: inner.minY)); hills.line(to: CGPoint(x: inner.minX, y: inner.minY))
        hill.setFill(); hills.fill()
        NSColor(srgbRed: 1, green: 0.84, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: inner.maxX - inner.width * 0.30, y: inner.maxY - inner.height * 0.34,
                                    width: inner.width * 0.16, height: inner.width * 0.16)).fill()
        NSGraphicsContext.current!.restoreGraphicsState()
        ctx.restoreGState()
    }
    card(CGRect(x: 250 * s, y: 330 * s, width: 440 * s, height: 360 * s), angle: 9,
         sky: NSColor(srgbRed: 0.70, green: 0.84, blue: 0.97, alpha: 1), hill: NSColor(srgbRed: 0.45, green: 0.66, blue: 0.52, alpha: 1))
    card(CGRect(x: 320 * s, y: 270 * s, width: 440 * s, height: 360 * s), angle: -5,
         sky: NSColor(srgbRed: 0.60, green: 0.80, blue: 0.98, alpha: 1), hill: NSColor(srgbRed: 0.30, green: 0.60, blue: 0.42, alpha: 1))

    // the check: merged, and verified
    let badge = CGRect(x: 608 * s, y: 176 * s, width: 230 * s, height: 230 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 18 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor(srgbRed: 0.20, green: 0.74, blue: 0.40, alpha: 1).setFill(); NSBezierPath(ovalIn: badge).fill()
    ctx.restoreGState()
    NSColor.white.setFill(); NSBezierPath(ovalIn: badge.insetBy(dx: 0, dy: 0)).lineWidth = 0
    let tick = NSBezierPath()
    tick.move(to: CGPoint(x: badge.minX + 58 * s, y: badge.midY))
    tick.line(to: CGPoint(x: badge.minX + 100 * s, y: badge.minY + 68 * s))
    tick.line(to: CGPoint(x: badge.maxX - 52 * s, y: badge.maxY - 66 * s))
    tick.lineWidth = 30 * s; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
    NSColor.white.setStroke(); tick.stroke()
    img.unlockFocus()
    return img
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.copyItem(at: set.appendingPathComponent("icon_512x512@2x.png"),
                                  to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
