// Renders the DiskScope app icon and packs it into Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift [output.icns]          (run from the package root)
//   ICON_PREVIEW_DIR=/some/dir swift scripts/make-icon.swift   also writes preview PNGs
//   ICON_DOCS=1 swift scripts/make-icon.swift            also refreshes docs/icon.png + docs/favicon-32.png
//
// A ringed planet in deep space: the rings double as a disk platter (fine grooves) and as
// usage rings (one pale-cyan arc), nodding to the app's sunburst view. Mostly monochrome
// silvers and steel blues. Pure CoreGraphics + ImageIO, so it runs headless. Star positions
// come from a fixed-seed generator, so the output is reproducible.
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

func gradient(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs)!
}

/// Deterministic PRNG (64-bit LCG) so the star field never changes between runs.
struct SeededRandom {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(Double(state >> 11) / Double(1 << 53))
    }
    mutating func range(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo + (hi - lo) * next() }
}

/// macOS-style squircle (superellipse) filling `rect`.
func squircle(_ rect: CGRect, exponent n: CGFloat = 4.4) -> CGPath {
    let p = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }

/// Level of detail: 0 = 16/32 px (bold silhouette), 1 = 64–128 px, 2 = 256 px and up.
func detailLevel(px: Int) -> Int { px <= 32 ? 0 : (px <= 128 ? 1 : 2) }

// MARK: - Scene geometry (1024-unit canvas, origin bottom-left)

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let planetCenter = CGPoint(x: 506, y: 508)
let tilt: CGFloat = 0.36          // ring plane rotation (radians, counter-clockwise)
var squash: CGFloat = 0.30        // ring ellipse height / width (viewing angle); opened up at tiny sizes
let lightDir = CGPoint(x: -0.62, y: 0.78) // towards the light: upper left

struct Band { let r0: CGFloat; let r1: CGFloat; let inner: UInt32; let outer: UInt32; let alpha: CGFloat }

func drawBackground(_ ctx: CGContext, detail: Int, unit: CGFloat) {
    // Deep space: navy at the top falling to near-black.
    ctx.drawLinearGradient(gradient([rgb(0x16204A), rgb(0x0A1030), rgb(0x04060F)], [0, 0.55, 1]),
                           start: CGPoint(x: 380, y: 924), end: CGPoint(x: 640, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Nebula haze: a cool violet bloom upper right, a steel-teal one lower left.
    ctx.drawRadialGradient(gradient([rgb(0x5A4FA8, 0.42), rgb(0x3A2F7A, 0.16), rgb(0x3A2F7A, 0)], [0, 0.45, 1]),
                           startCenter: CGPoint(x: 760, y: 790), startRadius: 0,
                           endCenter: CGPoint(x: 760, y: 790), endRadius: 470, options: [])
    ctx.drawRadialGradient(gradient([rgb(0x1E5C80, 0.30), rgb(0x1E5C80, 0)]),
                           startCenter: CGPoint(x: 230, y: 250), startRadius: 0,
                           endCenter: CGPoint(x: 230, y: 250), endRadius: 420, options: [])
    // A faint milky band running diagonally behind the planet.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: -0.62)
    ctx.scaleBy(x: 1, y: 0.22)
    ctx.drawRadialGradient(gradient([rgb(0xB9C8F0, 0.13), rgb(0xB9C8F0, 0)]),
                           startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 620, options: [])
    ctx.restoreGState()

    guard detail > 0 else {
        // Two bright points keep a hint of space at 16/32 px without becoming noise.
        for (p, r) in [(CGPoint(x: 230, y: 800), CGFloat(15)), (CGPoint(x: 820, y: 255), CGFloat(12))] {
            ctx.setFillColor(rgb(0xE6EEFF, 0.9))
            ctx.fillEllipse(in: circle(p, r))
        }
        return
    }

    // Star field, sized in device pixels so it stays crisp at every icon size.
    var rnd = SeededRandom(state: 0xD15C5C0DE)
    // Fewer stars as the icon shrinks, so smaller renders don't turn into speckle.
    let count = detail == 2 ? (unit <= 2 ? 170 : 90) : 26
    for _ in 0..<count {
        let p = CGPoint(x: rnd.range(105, 919), y: rnd.range(105, 919))
        let bright = rnd.next()
        let rPx = detail == 2 ? 0.45 + 1.2 * pow(bright, 3) : 0.5 + 0.45 * pow(bright, 2)
        let alpha = (detail == 2 ? 0.2 : 0.25) + 0.6 * pow(bright, 1.5)
        let tint: UInt32 = rnd.next() < 0.18 ? 0xC9D8FF : (rnd.next() < 0.1 ? 0xFFF1DC : 0xFFFFFF)
        ctx.setFillColor(rgb(tint, alpha))
        ctx.fillEllipse(in: circle(p, rPx * unit))
    }

    // A few hero stars with a soft glow and four-point diffraction spikes.
    let heroes: [(CGPoint, CGFloat)] = [
        (CGPoint(x: 236, y: 792), 1.0), (CGPoint(x: 812, y: 262), 0.8),
        (CGPoint(x: 838, y: 708), 0.55), (CGPoint(x: 178, y: 390), 0.45),
    ]
    for (p, s) in heroes {
        ctx.drawRadialGradient(gradient([rgb(0xDCE8FF, 0.55 * s), rgb(0x9DB8FF, 0.12 * s), rgb(0x9DB8FF, 0)], [0, 0.35, 1]),
                               startCenter: p, startRadius: 0, endCenter: p, endRadius: 46 * s, options: [])
        let len = 64 * s + 10, w = max(2.2 * s, 1.1 * unit)
        for angle in [0, CGFloat.pi / 2] {
            ctx.saveGState()
            ctx.translateBy(x: p.x, y: p.y)
            ctx.rotate(by: angle + 0.08)
            ctx.clip(to: CGRect(x: -len, y: -w / 2, width: 2 * len, height: w))
            ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0.85 * s), rgb(0xFFFFFF, 0)]),
                                   start: CGPoint(x: -len, y: 0), end: CGPoint(x: len, y: 0), options: [])
            ctx.restoreGState()
        }
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fillEllipse(in: circle(p, max(3.2 * s, 1.2 * unit)))
    }
}

/// Moves the context into the ring plane: origin at the planet, x along the ring's long axis.
/// Callers apply `scaleBy(1, squash)` themselves when drawing ring ellipses.
func enterRingSpace(_ ctx: CGContext) {
    ctx.translateBy(x: planetCenter.x, y: planetCenter.y)
    ctx.rotate(by: tilt)
}

func ringBands(detail: Int) -> [Band] {
    if detail == 0 {
        return [Band(r0: 232, r1: 312, inner: 0xF2F5FA, outer: 0xC3CCDB, alpha: 1),
                Band(r0: 326, r1: 372, inner: 0xAEB8CA, outer: 0x8994AA, alpha: 1)]
    }
    return [
        Band(r0: 212, r1: 236, inner: 0x6F7C96, outer: 0x8A97B0, alpha: 0.55),   // faint inner (C) ring
        Band(r0: 240, r1: 306, inner: 0xF4F7FC, outer: 0xC2CBDA, alpha: 1),      // bright main (B) ring
        Band(r0: 318, r1: 360, inner: 0xB4BED0, outer: 0x8691A8, alpha: 1),      // outer (A) ring
        Band(r0: 370, r1: 375, inner: 0xC9D3E4, outer: 0xC9D3E4, alpha: 0.5),    // thin outermost ring
    ]
}

/// Draws the rings' far half (`front == false`, behind the planet) or near half (over it).
func drawRings(_ ctx: CGContext, front: Bool, detail: Int, unit: CGFloat) {
    ctx.saveGState()
    enterRingSpace(ctx)
    // Half-plane: the far side of the ring is above the long axis, the near side below it.
    ctx.clip(to: front ? CGRect(x: -500, y: -500, width: 1000, height: 500)
                       : CGRect(x: -500, y: 0, width: 1000, height: 500))
    ctx.scaleBy(x: 1, y: squash)

    for band in ringBands(detail: detail) {
        ctx.saveGState()
        let annulus = CGMutablePath()
        annulus.addEllipse(in: circle(.zero, band.r1))
        annulus.addEllipse(in: circle(.zero, band.r0))
        ctx.addPath(annulus)
        ctx.clip(using: .evenOdd)
        ctx.setAlpha(band.alpha)
        ctx.drawRadialGradient(gradient([rgb(band.inner), rgb(band.outer)]),
                               startCenter: .zero, startRadius: band.r0, endCenter: .zero, endRadius: band.r1,
                               options: [])
        if detail == 2 {
            // Platter grooves: hairline concentric rings of alternating light and shade.
            var r = band.r0 + 3
            var i = 0
            while r < band.r1 - 1 {
                ctx.setStrokeColor(i % 2 == 0 ? rgb(0xFFFFFF, 0.16) : rgb(0x1A2238, 0.16))
                ctx.setLineWidth(1.4 * unit / squash * 0.55)
                ctx.strokeEllipse(in: circle(.zero, r))
                r += 4.5
                i += 1
            }
        }
        // Light falls from the left: shade the ring towards the right.
        ctx.setAlpha(1)
        ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.16), rgb(0x000000, 0), rgb(0x05070F, 0.42)], [0, 0.45, 1]),
                               start: CGPoint(x: -380, y: 0), end: CGPoint(x: 380, y: 0), options: [])
        ctx.restoreGState()
    }

    if !front {
        // The planet's shadow falls on the far ring, behind and to the right of the planet.
        ctx.saveGState()
        let shadow = CGMutablePath()
        shadow.addEllipse(in: circle(.zero, 380))
        ctx.addPath(shadow)
        ctx.clip()
        ctx.scaleBy(x: 1, y: 1 / squash)       // back to ring-plane space for a round shadow
        let c = CGPoint(x: 64, y: 10)
        ctx.drawRadialGradient(gradient([rgb(0x03050C, 0.62), rgb(0x03050C, 0.62), rgb(0x03050C, 0)], [0, 0.78, 1]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: 196, options: [])
        ctx.restoreGState()
    } else {
        // Usage arc: a pale-cyan segment on the outer ring, like the app's sunburst rings.
        let r0: CGFloat = detail == 0 ? 326 : 318, r1: CGFloat = detail == 0 ? 372 : 360
        let arc = CGMutablePath()
        let a0: CGFloat = .pi * 1.06, a1: CGFloat = .pi * 1.52
        arc.addArc(center: .zero, radius: r1, startAngle: a0, endAngle: a1, clockwise: false)
        arc.addArc(center: .zero, radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
        arc.closeSubpath()
        ctx.saveGState()
        ctx.addPath(arc)
        ctx.clip()
        ctx.drawRadialGradient(gradient([rgb(0xC8F4FF), rgb(0x6FD3F5)]),
                               startCenter: .zero, startRadius: r0, endCenter: .zero, endRadius: r1, options: [])
        if detail == 2 {
            var r = r0 + 3
            while r < r1 - 1 {
                ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
                ctx.setLineWidth(1.4 * unit / squash * 0.55)
                ctx.strokeEllipse(in: circle(.zero, r))
                r += 9
            }
        }
        ctx.restoreGState()
    }
    ctx.restoreGState()

    if front {
        // Soft glow around the cyan arc (drawn unclipped, beneath nothing else).
        ctx.saveGState()
        enterRingSpace(ctx)
        ctx.clip(to: CGRect(x: -500, y: -500, width: 1000, height: 500))
        ctx.scaleBy(x: 1, y: squash)
        let glow = CGMutablePath()
        glow.addArc(center: .zero, radius: detail == 0 ? 349 : 339, startAngle: .pi * 1.08, endAngle: .pi * 1.50,
                    clockwise: false)
        ctx.setShadow(offset: .zero, blur: 26, color: rgb(0x7FDcFF, detail == 0 ? 0 : 0.85))
        ctx.setStrokeColor(rgb(0x9BE6FF, detail == 0 ? 0 : 0.30))
        ctx.setLineWidth(4)
        ctx.addPath(glow)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

func drawPlanet(_ ctx: CGContext, detail: Int, unit: CGFloat) {
    let R: CGFloat = 176
    let c = planetCenter
    let hot = CGPoint(x: c.x + lightDir.x * R * 0.45, y: c.y + lightDir.y * R * 0.45)

    // Atmospheric halo.
    ctx.drawRadialGradient(gradient([rgb(0x9ADFFF, 0), rgb(0x9ADFFF, detail == 0 ? 0.10 : 0.20), rgb(0x9ADFFF, 0)],
                                    [0, 0.3, 1]),
                           startCenter: c, startRadius: R * 0.97, endCenter: c, endRadius: R * 1.32, options: [])

    let disc = CGPath(ellipseIn: circle(c, R), transform: nil)
    ctx.saveGState()
    ctx.addPath(disc)
    ctx.clip()
    // Sphere shading: a soft hot spot towards the light, falling to steel blue.
    ctx.drawRadialGradient(gradient([rgb(0xF4F7FC), rgb(0xC4CFDE), rgb(0x8B9AB3), rgb(0x56657F)], [0, 0.3, 0.68, 1]),
                           startCenter: hot, startRadius: 0, endCenter: c, endRadius: R * 1.08,
                           options: [.drawsAfterEndLocation])
    if detail > 0 {
        // Gas-giant cloud bands, parallel to the rings and curved like latitude lines.
        ctx.saveGState()
        enterRingSpace(ctx)
        let stripes: [(CGFloat, CGFloat, UInt32, CGFloat)] = [
            (128, 26, 0x2A3552, 0.20), (92, 12, 0xFFFFFF, 0.16), (58, 30, 0x2A3552, 0.16),
            (18, 14, 0xFFFFFF, 0.12), (-22, 34, 0x2A3552, 0.14), (-70, 14, 0xFFFFFF, 0.10),
            (-110, 28, 0x2A3552, 0.14), (-150, 12, 0xFFFFFF, 0.08),
        ]
        for (y, h, color, a) in stripes {
            // Soft-edged band parallel to the ring plane.
            ctx.saveGState()
            ctx.clip(to: CGRect(x: -R * 1.5, y: y - h, width: R * 3, height: 2 * h))
            ctx.drawLinearGradient(gradient([rgb(color, 0), rgb(color, a), rgb(color, 0)]),
                                   start: CGPoint(x: 0, y: y - h), end: CGPoint(x: 0, y: y + h), options: [])
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
    // Night side: everything outside a "lit" disc pushed towards the light, with a short soft edge
    // so the terminator reads crisp. Gibbous: most of the planet stays lit.
    let push: CGFloat = detail == 0 ? 0.30 : 0.42
    let litCenter = CGPoint(x: c.x + lightDir.x * R * push, y: c.y + lightDir.y * R * push)
    ctx.drawRadialGradient(gradient([rgb(0x04060D, 0), rgb(0x04060D, 0), rgb(0x04060D, detail == 0 ? 0.72 : 0.9)],
                                    [0, 0.88, 1]),
                           startCenter: litCenter, startRadius: 0, endCenter: litCenter, endRadius: R * 1.14,
                           options: [.drawsAfterEndLocation])
    // The near ring's shadow on the globe: the ring's near half, dropped a little lower.
    if detail > 0 {
        ctx.saveGState()
        enterRingSpace(ctx)
        ctx.translateBy(x: 0, y: -26)
        ctx.clip(to: CGRect(x: -500, y: -500, width: 1000, height: 500))
        ctx.scaleBy(x: 1, y: squash)
        let shadow = CGMutablePath()
        shadow.addEllipse(in: circle(.zero, 306))
        shadow.addEllipse(in: circle(.zero, 240))
        ctx.addPath(shadow)
        ctx.setFillColor(rgb(0x04060D, 0.34))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // Limb lighting: a bright cool rim on the sunlit edge, a faint violet back-scatter on the
    // night edge so the silhouette never melts into the background.
    ctx.saveGState()
    let rim = CGMutablePath()
    rim.addEllipse(in: circle(c, R))
    rim.addEllipse(in: circle(c, R - (detail == 0 ? 16 : 7)))
    ctx.addPath(rim)
    ctx.clip(using: .evenOdd)
    let litEdge = CGPoint(x: c.x + lightDir.x * R, y: c.y + lightDir.y * R)
    let darkEdge = CGPoint(x: c.x - lightDir.x * R, y: c.y - lightDir.y * R)
    ctx.drawLinearGradient(gradient([rgb(0xD2F4FF, 0.85), rgb(0x8FD8FF, 0.28), rgb(0x8FD8FF, 0), rgb(0x8E8CFF, 0),
                                     rgb(0x9C98FF, 0.5)], [0, 0.3, 0.55, 0.75, 1]),
                           start: litEdge, end: darkEdge, options: [])
    ctx.restoreGState()
}

/// A small moon keeping the planet company (skipped at tiny sizes).
func drawMoon(_ ctx: CGContext) {
    let c = CGPoint(x: 292, y: 262), r: CGFloat = 24
    ctx.drawRadialGradient(gradient([rgb(0xA9C4FF, 0.18), rgb(0xA9C4FF, 0)]),
                           startCenter: c, startRadius: r, endCenter: c, endRadius: r * 2.2, options: [])
    ctx.saveGState()
    ctx.addEllipse(in: circle(c, r))
    ctx.clip()
    let hot = CGPoint(x: c.x + lightDir.x * r * 0.5, y: c.y + lightDir.y * r * 0.5)
    ctx.drawRadialGradient(gradient([rgb(0xE9EEF6), rgb(0x9AA6BA), rgb(0x3A4458)], [0, 0.55, 1]),
                           startCenter: hot, startRadius: 0, endCenter: c, endRadius: r * 1.1,
                           options: [.drawsAfterEndLocation])
    let lit = CGPoint(x: c.x + lightDir.x * r * 0.5, y: c.y + lightDir.y * r * 0.5)
    ctx.drawRadialGradient(gradient([rgb(0x04060D, 0), rgb(0x04060D, 0), rgb(0x04060D, 0.88)], [0, 0.86, 1]),
                           startCenter: lit, startRadius: 0, endCenter: lit, endRadius: r * 1.18,
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext, px: Int) {
    let detail = detailLevel(px: px)
    let unit = 1024 / CGFloat(px)          // one device pixel, in canvas units
    squash = detail == 0 ? 0.40 : 0.30
    let bodyPath = squircle(body)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.5))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0x070A18))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    drawBackground(ctx, detail: detail, unit: unit)
    if detail > 0 { drawMoon(ctx) }
    if detail == 0 {
        // Tiny sizes: enlarge the planet so its silhouette carries the icon.
        ctx.translateBy(x: 512, y: 512)
        ctx.scaleBy(x: 1.1, y: 1.1)
        ctx.translateBy(x: -512, y: -512)
    }
    drawRings(ctx, front: false, detail: detail, unit: unit)
    drawPlanet(ctx, detail: detail, unit: unit)
    drawRings(ctx, front: true, detail: detail, unit: unit)
    // Glass-like top sheen.
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()

    // Hairline rim so the dark tile separates from dark docks and wallpapers.
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(rgb(0xB8C8FF, detail == 0 ? 0.22 : 0.16))
    ctx.setLineWidth(max(3, 1.2 * unit))
    ctx.strokePath()
}

func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    drawIcon(ctx, px: px)
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    precondition(CGImageDestinationFinalize(dest), "failed writing \(url.path)")
}

// MARK: - main

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    writePNG(render(px: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(px: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let env = ProcessInfo.processInfo.environment
if let preview = env["ICON_PREVIEW_DIR"] {
    for px in [1024, 512, 256, 128, 64, 32, 16] {
        writePNG(render(px: px), to: URL(fileURLWithPath: preview).appendingPathComponent("icon_\(px).png"))
    }
}
if env["ICON_DOCS"] == "1" {
    writePNG(render(px: 512), to: URL(fileURLWithPath: "docs/icon.png"))
    writePNG(render(px: 32), to: URL(fileURLWithPath: "docs/favicon-32.png"))
}

try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(out.path)")
