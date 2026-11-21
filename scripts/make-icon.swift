// Renders the DiskScope app icon and packs it into Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output.icns]   (run from the package root)
// Pure CoreGraphics + ImageIO, so it runs headless.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255, a])!
}

func mix(_ c: CGColor, _ d: CGColor, _ t: CGFloat) -> CGColor {
    let a = c.components!, b = d.components!
    return CGColor(colorSpace: space, components: (0..<4).map { a[$0] + (b[$0] - a[$0]) * t })!
}

func gradient(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs)!
}

let white = rgb(0xFFFFFF)

/// Annular sector; angles in radians, measured clockwise from 12 o'clock.
func sector(_ c: CGPoint, _ r0: CGFloat, _ r1: CGFloat, _ a0: CGFloat, _ a1: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let s = .pi / 2 - a0, e = .pi / 2 - a1
    p.addArc(center: c, radius: r1, startAngle: s, endAngle: e, clockwise: true)
    p.addArc(center: c, radius: r0, startAngle: e, endAngle: s, clockwise: false)
    p.closeSubpath()
    return p
}

struct Slice { let color: UInt32; let share: CGFloat; let outer: [CGFloat] }

// Inner ring = top-level folders; outer ring = their biggest children (gaps = small stuff).
let slices: [Slice] = [
    Slice(color: 0xFF5E7E, share: 0.34, outer: [0.45, 0.25, 0.15]),
    Slice(color: 0xFFA53D, share: 0.22, outer: [0.55, 0.30]),
    Slice(color: 0xFFD93D, share: 0.15, outer: [0.60, 0.25]),
    Slice(color: 0x3DDC97, share: 0.13, outer: [0.70]),
    Slice(color: 0x2EC5FF, share: 0.10, outer: [0.50, 0.35]),
    Slice(color: 0xB57BFF, share: 0.06, outer: [0.80]),
]

func drawIcon(_ ctx: CGContext, simple: Bool) {
    // ---- Body (Big Sur grid: 824pt squircle centred in 1024) ----
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.45))
    ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x1B1440)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x3B2B9E), rgb(0x23206B), rgb(0x0E1433)], [0, 0.5, 1]),
                           start: CGPoint(x: 180, y: 924), end: CGPoint(x: 844, y: 100), options: [])
    // soft glow behind the lens
    ctx.drawRadialGradient(gradient([rgb(0x7B5CFF, 0.55), rgb(0x7B5CFF, 0)]),
                           startCenter: CGPoint(x: 460, y: 580), startRadius: 0,
                           endCenter: CGPoint(x: 460, y: 580), endRadius: 420, options: [])
    // top sheen
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 620), options: [])
    ctx.restoreGState()
    // hairline rim
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.12)); ctx.setLineWidth(3); ctx.strokePath()

    // ---- Magnifier geometry ----
    let c = CGPoint(x: 466, y: 566)
    let lensR: CGFloat = 268          // outer edge of metal rim
    let rim: CGFloat = simple ? 44 : 34
    let glassR = lensR - rim

    // ---- Handle ----
    let hStart: CGFloat = lensR - 6, hLen: CGFloat = simple ? 250 : 250, hW: CGFloat = simple ? 96 : 90
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.rotate(by: -.pi / 4)
    let handle = CGPath(roundedRect: CGRect(x: hStart, y: -hW / 2, width: hLen, height: hW),
                        cornerWidth: hW / 2, cornerHeight: hW / 2, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 10, height: -6), blur: 22, color: rgb(0x000000, 0.5))
    ctx.addPath(handle); ctx.setFillColor(rgb(0x2A2440)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(handle); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFF8FB1), rgb(0xE0407A), rgb(0x8E1E57)], [0, 0.45, 1]),
                           start: CGPoint(x: 0, y: hW / 2), end: CGPoint(x: 0, y: -hW / 2), options: [])
    // specular stripe
    ctx.setFillColor(rgb(0xFFFFFF, 0.35))
    ctx.fill(CGRect(x: hStart + 40, y: hW * 0.18, width: hLen - 80, height: hW * 0.12))
    ctx.restoreGState()
    // metal collar where the handle meets the rim
    let collar = CGPath(roundedRect: CGRect(x: hStart - 14, y: -hW / 2 - 8, width: 46, height: hW + 16),
                        cornerWidth: 12, cornerHeight: 12, transform: nil)
    ctx.saveGState()
    ctx.addPath(collar); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xF4F6FB), rgb(0xA9B0C2), rgb(0x5D6478)], [0, 0.5, 1]),
                           start: CGPoint(x: 0, y: hW / 2 + 8), end: CGPoint(x: 0, y: -hW / 2 - 8), options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    // ---- Lens shadow + rim ----
    let lensCircle = CGPath(ellipseIn: CGRect(x: c.x - lensR, y: c.y - lensR, width: lensR * 2, height: lensR * 2), transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.55))
    ctx.addPath(lensCircle); ctx.setFillColor(rgb(0x9AA1B5)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(lensCircle); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), rgb(0xC9CEDB), rgb(0x7A8196), rgb(0xD5D9E4)], [0, 0.35, 0.7, 1]),
                           start: CGPoint(x: c.x - lensR, y: c.y + lensR), end: CGPoint(x: c.x + lensR, y: c.y - lensR), options: [])
    ctx.restoreGState()

    // ---- Glass interior ----
    let glass = CGPath(ellipseIn: CGRect(x: c.x - glassR, y: c.y - glassR, width: glassR * 2, height: glassR * 2), transform: nil)
    ctx.saveGState()
    ctx.addPath(glass); ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(0x24205A), rgb(0x0B0C24)]),
                           startCenter: c, startRadius: 0, endCenter: c, endRadius: glassR, options: [])

    // ---- Sunburst ----
    let hubR: CGFloat = simple ? 52 : 62
    let r1a: CGFloat = simple ? 60 : 72, r1b: CGFloat = simple ? 140 : 140
    let r2a: CGFloat = simple ? 140 : 148, r2b: CGFloat = glassR - (simple ? 0 : 14)
    let gap: CGFloat = simple ? 0.0 : 0.022
    var a: CGFloat = 0.02 * .pi * 2   // small rotation so the first gap isn't at 12 o'clock
    let full: CGFloat = .pi * 2

    for s in slices {
        let span = s.share * full
        let base = rgb(s.color)
        let a0 = a + gap / 2, a1 = a + span - gap / 2
        // inner ring
        ctx.saveGState()
        ctx.addPath(sector(c, r1a, r1b, a0, a1)); ctx.clip()
        ctx.drawRadialGradient(gradient([mix(base, white, 0.35), base]),
                               startCenter: c, startRadius: r1a, endCenter: c, endRadius: r1b, options: [])
        ctx.restoreGState()
        // outer ring children
        if !simple {
            var b = a
            for (i, f) in s.outer.enumerated() {
                let sub = span * f
                let b0 = b + gap / 2, b1 = b + sub - gap / 2
                let shade = mix(base, rgb(0x000000), 0.10 + CGFloat(i) * 0.12)
                ctx.saveGState()
                ctx.addPath(sector(c, r2a, r2b, b0, b1)); ctx.clip()
                ctx.drawRadialGradient(gradient([mix(shade, white, 0.15), shade]),
                                       startCenter: c, startRadius: r2a, endCenter: c, endRadius: r2b, options: [])
                ctx.restoreGState()
                b += sub
            }
        } else {
            // small sizes: one solid outer band per slice, slightly darker
            ctx.addPath(sector(c, r2a, r2b, a0, a + span * s.outer.reduce(0, +)))
            ctx.setFillColor(mix(base, rgb(0x000000), 0.15)); ctx.fillPath()
        }
        a += span
    }

    // ---- Hub: a tiny platter ----
    ctx.addEllipse(in: CGRect(x: c.x - hubR, y: c.y - hubR, width: hubR * 2, height: hubR * 2))
    ctx.setFillColor(rgb(0x0B0C24)); ctx.fillPath()
    if !simple {
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.10)); ctx.setLineWidth(2)
        for r in stride(from: hubR - 14, through: 26, by: -10) {
            ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)); ctx.strokePath()
        }
    }
    let spR: CGFloat = simple ? 20 : 16
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - spR, y: c.y - spR, width: spR * 2, height: spR * 2)); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), rgb(0x9AA1B5)]),
                           start: CGPoint(x: c.x - spR, y: c.y + spR), end: CGPoint(x: c.x + spR, y: c.y - spR), options: [])
    ctx.restoreGState()

    // ---- Glass reflections ----
    if !simple {
        // broad soft sheen, upper-left
        ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.30), rgb(0xFFFFFF, 0)]),
                               startCenter: CGPoint(x: c.x - glassR * 0.45, y: c.y + glassR * 0.5), startRadius: 0,
                               endCenter: CGPoint(x: c.x - glassR * 0.45, y: c.y + glassR * 0.5), endRadius: glassR * 0.95,
                               options: [])
        // crisp crescent highlight
        let arc = CGMutablePath()
        arc.addArc(center: c, radius: glassR - 22, startAngle: .pi * 0.62, endAngle: .pi * 0.92, clockwise: false)
        ctx.addPath(arc)
        ctx.setLineCap(.round); ctx.setLineWidth(16)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.55)); ctx.strokePath()
    }
    ctx.restoreGState()

    // inner rim edge
    ctx.addPath(glass); ctx.setStrokeColor(rgb(0x000000, 0.35)); ctx.setLineWidth(4); ctx.strokePath()
}

func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    drawIcon(ctx, simple: px <= 32)
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    precondition(CGImageDestinationFinalize(dest), "failed writing \(url.path)")
}

// ---- main ----
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    writePNG(render(px: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(px: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let preview = ProcessInfo.processInfo.environment["ICON_PREVIEW_DIR"] {
    for px in [1024, 512, 128, 32, 16] {
        writePNG(render(px: px), to: URL(fileURLWithPath: preview).appendingPathComponent("icon_\(px).png"))
    }
}

try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(out.path)")
