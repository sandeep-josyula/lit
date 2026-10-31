// Draws the LIT app icon: a white lowercase "lit" on a jet-black tile, the dot of the i a
// single amber light. Writes Assets/AppIcon.icns.
//   swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let size: CGFloat = 1024

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Draws "lit" in white with the dot of the i in amber. The dot is the font's own tittle (the
/// top part of the "i" glyph), so its shape and position are exactly the typeface's.
func drawWordmark(in ctx: CGContext, size: CGFloat, centre: CGPoint, letters: NSColor = .white) {
    let font = CTFontCreateWithName("SF Pro Display Semibold" as CFString, size, nil)
    let base = NSFont.systemFont(ofSize: size, weight: .semibold) as CTFont
    let f = CTFontCopyPostScriptName(font) as String == "SFProDisplay-Semibold" ? font : base
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "lit", attributes: [
        .font: f, .kern: -size * 0.01,
    ]))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let origin = CGPoint(x: centre.x - bounds.midX, y: centre.y - bounds.midY)

    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    for run in runs {
        let n = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: n)
        var positions = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
        for k in 0..<n {
            guard let path = CTFontCreatePathForGlyph(f, glyphs[k], nil) else { continue }
            var t = CGAffineTransform(translationX: origin.x + positions[k].x, y: origin.y + positions[k].y)
            guard let placed = path.copy(using: &t) else { continue }
            // Split the glyph into its separate shapes; for "i" the highest one is the dot.
            var parts: [CGMutablePath] = []
            placed.applyWithBlock { el in
                let e = el.pointee
                switch e.type {
                case .moveToPoint: parts.append(CGMutablePath()); parts.last!.move(to: e.points[0])
                case .addLineToPoint: parts.last?.addLine(to: e.points[0])
                case .addQuadCurveToPoint: parts.last?.addQuadCurve(to: e.points[1], control: e.points[0])
                case .addCurveToPoint: parts.last?.addCurve(to: e.points[2], control1: e.points[0], control2: e.points[1])
                case .closeSubpath: parts.last?.closeSubpath()
                @unknown default: break
                }
            }
            let isI = k == 1 && parts.count >= 2
            let dot = isI ? parts.max { $0.boundingBox.minY < $1.boundingBox.minY } : nil
            for part in parts {
                ctx.addPath(part)
                ctx.setFillColor(part === dot ? color(0xFFB020).cgColor : letters.cgColor)
                ctx.fillPath(using: .winding)
            }
        }
    }
}

func draw() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824 pt rounded square centred on a 1024 canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    // A hairline edge so the tile reads on dark Docks.
    color(0xFFFFFF, 0.10).setStroke()
    let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
    edge.lineWidth = 3
    edge.stroke()

    drawWordmark(in: NSGraphicsContext.current!.cgContext, size: 400, centre: CGPoint(x: tile.midX, y: tile.midY - 6))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let rep = draw()
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = iconset.appendingPathComponent("master.png")
try rep.representation(using: .png, properties: [:])!.write(to: master)

for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-z", "\(px)", "\(px)", master.path, "--out", iconset.appendingPathComponent(name).path]
        p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
    }
}
try fm.removeItem(at: master)
let out = root.appendingPathComponent("Assets/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Assets/AppIcon.png"))

// The wordmark alone (transparent): white letters for the app and dark pages, black letters
// for light pages (the README on a light theme).
func writeWordmark(letters: NSColor, to name: String) throws {
    let wm = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: wm)
    drawWordmark(in: NSGraphicsContext.current!.cgContext, size: 240, centre: CGPoint(x: 300, y: 150), letters: letters)
    NSGraphicsContext.restoreGraphicsState()
    // Trim to the drawn pixels (plus a hair of padding).
    var minX = wm.pixelsWide, minY = wm.pixelsHigh, maxX = 0, maxY = 0
    for y in 0..<wm.pixelsHigh { for x in 0..<wm.pixelsWide where wm.colorAt(x: x, y: y)!.alphaComponent > 0.01 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
    let tight = wm.cgImage!.cropping(to: CGRect(x: minX - 2, y: minY - 2, width: maxX - minX + 5, height: maxY - minY + 5))!
    try NSBitmapImageRep(cgImage: tight).representation(using: .png, properties: [:])!
        .write(to: root.appendingPathComponent("Assets/\(name)"))
}
try writeWordmark(letters: .white, to: "Wordmark.png")
try writeWordmark(letters: .black, to: "Wordmark-light.png")
print("Wrote wordmarks")
