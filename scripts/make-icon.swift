// Renders the DiskScope app icon and packs it into Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift [output.icns]          (run from the package root)
//   ICON_PREVIEW_DIR=/some/dir swift scripts/make-icon.swift   also writes preview PNGs
//   ICON_DOCS=1 swift scripts/make-icon.swift            also refreshes docs/icon.png + docs/favicon-32.png
//
// A sci-fi disk scanner: a machined gunmetal device whose black-glass face shows a disk platter
// under a holographic HUD — a segmented usage gauge, tick rings, targeting brackets and a radar
// sweep that has just locked onto something (the one amber pip). One emissive colour family
// (cyan/teal) plus that amber accent. Detail is reduced per size so 16/32 px keep a bold
// silhouette. Pure CoreGraphics + ImageIO, so it runs headless; deterministic output.
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

func polar(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: C.x + r * cos(a), y: C.y + r * sin(a)) }

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

/// Ring sector between radii r0…r1 from angle a0 to a1 (radians, counter-clockwise, y up).
func sector(_ r0: CGFloat, _ r1: CGFloat, _ a0: CGFloat, _ a1: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addArc(center: C, radius: r1, startAngle: a0, endAngle: a1, clockwise: false)
    p.addArc(center: C, radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
    p.closeSubpath()
    return p
}

func ring(_ r0: CGFloat, _ r1: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addEllipse(in: circle(C, r1))
    p.addEllipse(in: circle(C, r0))
    return p
}

/// Level of detail: 0 = 16/32 px (bold silhouette), 1 = 64–128 px, 2 = 256 px and up.
func detailLevel(px: Int) -> Int { px <= 32 ? 0 : (px <= 128 ? 1 : 2) }

// MARK: - Palette and geometry (1024-unit canvas, origin bottom-left)

let C = CGPoint(x: 512, y: 512)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let cyan: UInt32 = 0x46EEFF       // emissive HUD colour
let cyanHot: UInt32 = 0xD8FCFF    // overexposed core of the glow
let teal: UInt32 = 0x0B8FA3       // dim HUD elements
let amber: UInt32 = 0xFFB238      // the single warm accent: a lock-on

/// Per-size geometry. Tiny renders enlarge the platter and thicken every stroke.
struct Layout {
    let platter: CGFloat          // platter radius
    let gauge: (CGFloat, CGFloat) // segmented usage gauge band
    let ticks: (CGFloat, CGFloat) // tick ring band
    let hub: CGFloat              // spindle radius
    let sweepLead: CGFloat        // radar sweep leading edge angle
    let sweepSpan: CGFloat        // how far the sweep's afterglow trails
    let gaugeFill: CGFloat        // fraction of the gauge lit
    init(detail: Int) {
        if detail == 0 {
            platter = 262; gauge = (290, 362); ticks = (0, 0); hub = 92
        } else {
            platter = 246; gauge = (276, 300); ticks = (314, 328); hub = 62
        }
        sweepLead = deg(52); sweepSpan = deg(detail == 0 ? 80 : 95); gaugeFill = 0.72
    }
}

// MARK: - Layers

/// Machined gunmetal tile with a bevelled frame around a black-glass face.
func drawChassis(_ ctx: CGContext, detail: Int, unit: CGFloat) {
    // Frame: brushed gunmetal, lit from the top left.
    ctx.drawLinearGradient(gradient([rgb(0x56616D), rgb(0x2A323B), rgb(0x161B21), rgb(0x0C1014)], [0, 0.35, 0.7, 1]),
                           start: CGPoint(x: 180, y: 940), end: CGPoint(x: 840, y: 90), options: [])
    if detail == 2 {
        // Fine horizontal brushing on the frame.
        var y: CGFloat = 100
        var i = 0
        while y < 924 {
            ctx.setFillColor(i % 3 == 0 ? rgb(0xFFFFFF, 0.025) : rgb(0x000000, 0.03))
            ctx.fill(CGRect(x: 100, y: y, width: 824, height: max(unit, 1.2)))
            y += max(unit * 2, 3.1)
            i += 1
        }
    }
    let inset: CGFloat = detail == 0 ? 30 : 34
    let face = squircle(body.insetBy(dx: inset, dy: inset), exponent: 4.6)

    // Chamfer: a lit edge on the upper left and a dark one lower right, just outside the face.
    ctx.saveGState()
    let chamfer = CGMutablePath()
    chamfer.addPath(squircle(body.insetBy(dx: inset - 9, dy: inset - 9), exponent: 4.6))
    chamfer.addPath(face)
    ctx.addPath(chamfer)
    ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(gradient([rgb(0xC9D4DF, 0.75), rgb(0x6C7884, 0.3), rgb(0x05070A, 0.8)], [0, 0.45, 1]),
                           start: CGPoint(x: 200, y: 900), end: CGPoint(x: 820, y: 120), options: [])
    ctx.restoreGState()

    // Black glass face: graphite with a cool cast, slightly lighter at the top.
    ctx.saveGState()
    ctx.addPath(face)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x15202A), rgb(0x0A1016), rgb(0x05080B)], [0, 0.5, 1]),
                           start: CGPoint(x: 512, y: 900), end: CGPoint(x: 512, y: 120), options: [])
    // The HUD lights the glass from within.
    ctx.drawRadialGradient(gradient([rgb(teal, 0.30), rgb(teal, 0.10), rgb(teal, 0)], [0, 0.5, 1]),
                           startCenter: C, startRadius: 0, endCenter: C, endRadius: 430, options: [])
    if detail == 2 { drawHexGrid(ctx, unit: unit) }
    ctx.restoreGState()
}

/// Faint hexagonal micro-grid on the glass, fading out towards the edges.
func drawHexGrid(_ ctx: CGContext, unit: CGFloat) {
    let s: CGFloat = 26                  // hex radius
    let w = s * sqrt(3), h = s * 1.5
    ctx.setLineWidth(max(unit * 0.8, 1))
    var row = 0
    var y: CGFloat = 80
    while y < 960 {
        var x: CGFloat = 80 + (row % 2 == 0 ? 0 : w / 2)
        while x < 960 {
            let d = hypot(x - C.x, y - C.y)
            let a = max(0, 0.075 * (1 - d / 470))
            if a > 0.004 {
                let p = CGMutablePath()
                for k in 0..<6 {
                    let ang = deg(30 + 60 * CGFloat(k))
                    let pt = CGPoint(x: x + (s - 2) * cos(ang), y: y + (s - 2) * sin(ang))
                    k == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
                p.closeSubpath()
                ctx.setStrokeColor(rgb(cyan, a))
                ctx.addPath(p)
                ctx.strokePath()
            }
            x += w
        }
        y += h
        row += 1
    }
}

/// The disk platter: dark anodised metal with machining grooves and a two-lobed sheen.
func drawPlatter(_ ctx: CGContext, L: Layout, detail: Int, unit: CGFloat) {
    let R = L.platter
    // Recess shadow around the platter.
    ctx.drawRadialGradient(gradient([rgb(0x000000, 0.55), rgb(0x000000, 0)]),
                           startCenter: C, startRadius: R, endCenter: C, endRadius: R + 34, options: [])
    ctx.saveGState()
    ctx.addEllipse(in: circle(C, R))
    ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(0x26313C), rgb(0x161D25), rgb(0x0B1015)], [0, 0.6, 1]),
                           startCenter: CGPoint(x: C.x - 40, y: C.y + 50), startRadius: 0,
                           endCenter: C, endRadius: R, options: [.drawsAfterEndLocation])
    // Anisotropic sheen of a polished platter: two bright lobes opposite each other.
    let steps = detail == 0 ? 90 : 360
    for i in 0..<steps {
        let a0 = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let a1 = CGFloat(i + 1) / CGFloat(steps) * 2 * .pi + 0.002
        let lobe = pow(max(0, cos(2 * ((a0 + a1) / 2 - deg(128)))), 10)
        if lobe < 0.01 { continue }
        ctx.setFillColor(rgb(0xC6DCEC, 0.22 * lobe))
        ctx.addPath(sector(L.hub, R, a0, a1))
        ctx.fillPath()
    }
    if detail > 0 {
        // Machining grooves.
        var r = L.hub + 10
        var i = 0
        let step: CGFloat = detail == 2 ? max(3, unit * 1.5) : 9
        ctx.setLineWidth(max(unit * 0.6, 0.8))
        while r < R - 2 {
            // Faint, fine and irregular: polished metal, not record grooves.
            let a: CGFloat = i % 7 == 0 ? 0.05 : 0.018
            ctx.setStrokeColor(i % 2 == 0 ? rgb(0xFFFFFF, a) : rgb(0x000000, 0.10))
            ctx.strokeEllipse(in: circle(C, r))
            r += step
            i += 1
        }
    }
    ctx.restoreGState()
    if detail > 0 {
        // Radar range rings.
        ctx.saveGState()
        ctx.setLineWidth(max(unit, 1.5))
        ctx.setLineDash(phase: 0, lengths: [6, 9])
        ctx.setStrokeColor(rgb(cyan, 0.16))
        for f: CGFloat in detail == 2 ? [0.46, 0.74] : [0.6] { ctx.strokeEllipse(in: circle(C, R * f)) }
        ctx.restoreGState()
        // The lit gauge reflected in the platter's polished rim (right-hand side).
        ctx.saveGState()
        ctx.addPath(ring(R - 16, R - 2))
        ctx.clip(using: .evenOdd)
        ctx.drawLinearGradient(gradient([rgb(cyan, 0), rgb(cyan, 0.22)]),
                               start: CGPoint(x: C.x - R * 0.2, y: C.y), end: CGPoint(x: C.x + R, y: C.y), options: [])
        ctx.restoreGState()
    }
    // Polished platter edge.
    ctx.setLineWidth(detail == 0 ? 8 : 3)
    ctx.setStrokeColor(rgb(0x8FA2B4, detail == 0 ? 0.55 : 0.45))
    ctx.strokeEllipse(in: circle(C, R - 1.5))
}

/// Radar sweep: an afterglow wedge trailing a bright leading edge.
func drawSweep(_ ctx: CGContext, L: Layout, detail: Int) {
    let R = L.platter - 4
    let steps = detail == 0 ? 40 : 160
    for i in 0..<steps {
        let t0 = CGFloat(i) / CGFloat(steps), t1 = CGFloat(i + 1) / CGFloat(steps)
        let a0 = L.sweepLead - L.sweepSpan * (1 - t0)
        let a1 = L.sweepLead - L.sweepSpan * (1 - t1) + 0.003
        let alpha = (detail == 0 ? 0.62 : 0.46) * pow(t1, 2.2)
        ctx.setFillColor(rgb(cyan, alpha))
        ctx.addPath(sector(L.hub * 0.6, R, a0, a1))
        ctx.fillPath()
    }
    // Depth: the afterglow fades towards the hub.
    if detail > 0 {
        ctx.saveGState()
        ctx.addPath(sector(L.hub * 0.6, R, L.sweepLead - L.sweepSpan, L.sweepLead + 0.01))
        ctx.clip()
        ctx.drawRadialGradient(gradient([rgb(0x05080B, 0.55), rgb(0x05080B, 0)]),
                               startCenter: C, startRadius: L.hub, endCenter: C, endRadius: R * 0.85, options: [])
        ctx.restoreGState()
    }
    // Leading edge with bloom.
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setShadow(offset: .zero, blur: detail == 0 ? 0 : 30, color: rgb(cyan, 0.95))
    ctx.setStrokeColor(rgb(detail == 0 ? cyan : cyanHot))
    ctx.setLineWidth(detail == 0 ? 20 : 6)
    ctx.move(to: polar(L.hub * 0.9, L.sweepLead))
    ctx.addLine(to: polar(R, L.sweepLead))
    ctx.strokePath()
    ctx.restoreGState()
}

/// HUD rings: segmented usage gauge, tick ring, inner reticle and targeting brackets.
func drawHUD(_ ctx: CGContext, L: Layout, detail: Int, unit: CGFloat) {
    let (g0, g1) = L.gauge
    let start = deg(90)                         // gauge fills clockwise from 12 o'clock
    let lit = 2 * .pi * L.gaugeFill
    if detail == 0 {
        // Solid gauge: lit arc plus a dim track for the rest.
        ctx.setFillColor(rgb(teal, 0.38))
        ctx.addPath(sector(g0, g1, start + deg(8), start + 2 * .pi - lit - deg(8)))
        ctx.fillPath()
        ctx.setFillColor(rgb(cyan))
        ctx.addPath(sector(g0, g1, start - lit, start - deg(6)))
        ctx.fillPath()
    } else {
        // Segmented gauge with bloom on the lit blocks.
        let block = deg(detail == 2 ? 5 : 10), gap = deg(detail == 2 ? 1.6 : 3)
        var a = start
        let end = start - 2 * .pi + block
        while a > end {
            let isLit = (start - a) < lit
            let p = sector(g0, g1, a - block + gap / 2, a - gap / 2)
            ctx.saveGState()
            if isLit { ctx.setShadow(offset: .zero, blur: 18, color: rgb(cyan, 0.8)) }
            ctx.setFillColor(isLit ? rgb(cyan, 0.95) : rgb(teal, 0.28))
            ctx.addPath(p)
            ctx.fillPath()
            ctx.restoreGState()
            a -= block
        }
        // Thin track rings hugging the gauge.
        ctx.setLineWidth(max(unit, 2))
        ctx.setStrokeColor(rgb(cyan, 0.35))
        ctx.strokeEllipse(in: circle(C, g0 - 8))
        ctx.strokeEllipse(in: circle(C, g1 + 8))

        // Tick ring: minor every 5°, major every 30°.
        let (t0, t1) = L.ticks
        let every: CGFloat = detail == 2 ? 5 : 15
        var d: CGFloat = 0
        while d < 360 {
            let major = d.truncatingRemainder(dividingBy: 30) == 0
            ctx.setStrokeColor(rgb(cyan, major ? 0.85 : 0.40))
            ctx.setLineWidth(major ? max(4, 1.6 * unit) : max(1.6, unit))
            ctx.move(to: polar(major ? t0 - 4 : t0 + 3, deg(d)))
            ctx.addLine(to: polar(major ? t1 + 6 : t1, deg(d)))
            ctx.strokePath()
            d += every
        }
        // Crosshair notches at the cardinal points.
        ctx.setLineCap(.butt)
        for k in 0..<4 {
            let a = deg(90 * CGFloat(k))
            ctx.setStrokeColor(rgb(cyan, 0.9))
            ctx.setLineWidth(7)
            ctx.move(to: polar(t1 + 14, a))
            ctx.addLine(to: polar(t1 + 40, a))
            ctx.strokePath()
        }
        // Targeting brackets in the four corners.
        let o: CGFloat = 318, arm: CGFloat = 62
        ctx.setLineWidth(detail == 2 ? 7 : 10)
        ctx.setLineJoin(.miter)
        ctx.setStrokeColor(rgb(cyan, 0.75))
        for (sx, sy) in [(CGFloat(1), CGFloat(1)), (-1, 1), (1, -1), (-1, -1)] {
            let corner = CGPoint(x: C.x + sx * o, y: C.y + sy * o)
            ctx.move(to: CGPoint(x: corner.x - sx * arm, y: corner.y))
            ctx.addLine(to: corner)
            ctx.addLine(to: CGPoint(x: corner.x, y: corner.y - sy * arm))
            ctx.strokePath()
        }
        if detail == 2 { drawReadouts(ctx, unit: unit) }
    }
}

/// Tiny abstract data readouts (bars, no text) tucked by two brackets.
func drawReadouts(_ ctx: CGContext, unit: CGFloat) {
    let rows: [[CGFloat]] = [[38, 10, 22], [16, 30], [26, 8, 12, 6]]
    for (i, row) in rows.enumerated() {
        var x: CGFloat = 214
        let y: CGFloat = 790 - CGFloat(i) * 15
        for (j, w) in row.enumerated() {
            ctx.setFillColor(rgb(cyan, j == 0 ? 0.75 : 0.4))
            ctx.fill(CGRect(x: x, y: y, width: w, height: 6))
            x += w + 6
        }
    }
    // Bottom-right: a little bar graph.
    for (i, h) in [CGFloat(10), 18, 14, 28, 22, 34].enumerated() {
        ctx.setFillColor(rgb(cyan, i == 5 ? 0.85 : 0.45))
        ctx.fill(CGRect(x: 744 + CGFloat(i) * 11, y: 216, width: 7, height: h))
    }
}

/// The spindle: a machined disk clamp with screw holes and a glowing core.
func drawHub(_ ctx: CGContext, L: Layout, detail: Int) {
    let r = L.hub
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x000000, 0.7))
    ctx.setFillColor(rgb(0x1B232B))
    ctx.fillEllipse(in: circle(C, r))
    ctx.restoreGState()
    // Brushed clamp: lit from the upper left.
    ctx.saveGState()
    ctx.addEllipse(in: circle(C, r))
    ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(0xD5DEE6), rgb(0x7D8A97), rgb(0x2A333C)], [0, 0.5, 1]),
                           startCenter: CGPoint(x: C.x - r * 0.4, y: C.y + r * 0.45), startRadius: 0,
                           endCenter: C, endRadius: r * 1.05, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(0x0A0E12, 0.8))
    ctx.setLineWidth(detail == 0 ? 6 : 2.5)
    ctx.strokeEllipse(in: circle(C, r - 1))
    if detail > 0 {
        // Clamp screws.
        for k in 0..<6 {
            let a = deg(15 + 60 * CGFloat(k))
            let p = CGPoint(x: C.x + r * 0.72 * cos(a), y: C.y + r * 0.72 * sin(a))
            ctx.setFillColor(rgb(0x0B0F13, 0.9))
            ctx.fillEllipse(in: circle(p, r * 0.085))
        }
    }
    // Spindle cap with an emissive ring.
    let c0 = r * (detail == 0 ? 0.30 : 0.34), c1 = r * (detail == 0 ? 0.52 : 0.46)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: detail == 0 ? 0 : 18, color: rgb(cyan, 0.95))
    ctx.addPath(ring(c0, c1))
    ctx.setFillColor(rgb(detail == 0 ? cyan : 0x9FF6FF))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
    ctx.drawRadialGradient(gradient([rgb(0x3A4652), rgb(0x0B1014)]),
                           startCenter: CGPoint(x: C.x - c0 * 0.3, y: C.y + c0 * 0.3), startRadius: 0,
                           endCenter: C, endRadius: c0, options: [])
}

/// The lock-on: an amber blip inside the sweep's afterglow, with a target ring.
func drawBlip(_ ctx: CGContext, L: Layout, detail: Int) {
    let p = polar(L.platter * (detail == 0 ? 0.6 : 0.64), L.sweepLead - deg(detail == 0 ? 34 : 26))
    let r: CGFloat = detail == 0 ? 46 : 15
    ctx.drawRadialGradient(gradient([rgb(amber, 0.55), rgb(amber, 0)]),
                           startCenter: p, startRadius: r * 0.5, endCenter: p, endRadius: r * 3.4, options: [])
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: detail == 0 ? 0 : 16, color: rgb(amber, 0.9))
    ctx.setFillColor(rgb(amber))
    ctx.fillEllipse(in: circle(p, r))
    ctx.restoreGState()
    ctx.setFillColor(rgb(0xFFF1D6, 0.9))
    ctx.fillEllipse(in: circle(p, r * 0.42))
    if detail > 0 {
        ctx.setStrokeColor(rgb(amber, 0.8))
        ctx.setLineWidth(detail == 2 ? 3.5 : 6)
        ctx.strokeEllipse(in: circle(p, r * 2.3))
        // Lock brackets around the target.
        let s = r * 3.1, arm = r * 1.1
        ctx.setLineWidth(detail == 2 ? 3.5 : 6)
        for (sx, sy) in [(CGFloat(1), CGFloat(1)), (-1, 1), (1, -1), (-1, -1)] {
            let corner = CGPoint(x: p.x + sx * s, y: p.y + sy * s)
            ctx.move(to: CGPoint(x: corner.x - sx * arm, y: corner.y))
            ctx.addLine(to: corner)
            ctx.addLine(to: CGPoint(x: corner.x, y: corner.y - sy * arm))
            ctx.strokePath()
        }
    }
}

/// CRT-style scanlines and a glass reflection over the face.
func drawGlass(_ ctx: CGContext, detail: Int, unit: CGFloat, px: Int) {
    if detail == 2 && px >= 512 {
        var y: CGFloat = 100
        while y < 924 {
            ctx.setFillColor(rgb(0x000000, 0.10))
            ctx.fill(CGRect(x: 100, y: y, width: 824, height: unit * 1.2))
            y += unit * 4
        }
    }
    // Diagonal glass reflection across the upper left.
    ctx.saveGState()
    let sheen = CGMutablePath()
    sheen.move(to: CGPoint(x: 100, y: 924))
    sheen.addLine(to: CGPoint(x: 640, y: 924))
    sheen.addCurve(to: CGPoint(x: 100, y: 420), control1: CGPoint(x: 430, y: 760), control2: CGPoint(x: 260, y: 560))
    sheen.closeSubpath()
    ctx.addPath(sheen)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, detail == 0 ? 0.05 : 0.08), rgb(0xFFFFFF, 0)]),
                           start: CGPoint(x: 200, y: 900), end: CGPoint(x: 420, y: 600), options: [])
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext, px: Int) {
    let detail = detailLevel(px: px)
    let unit = 1024 / CGFloat(px)          // one device pixel, in canvas units
    let L = Layout(detail: detail)
    let bodyPath = squircle(body)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.5))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0x0C1014))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    drawChassis(ctx, detail: detail, unit: unit)
    drawPlatter(ctx, L: L, detail: detail, unit: unit)
    drawSweep(ctx, L: L, detail: detail)
    drawHUD(ctx, L: L, detail: detail, unit: unit)
    drawHub(ctx, L: L, detail: detail)
    drawBlip(ctx, L: L, detail: detail)
    drawGlass(ctx, detail: detail, unit: unit, px: px)
    ctx.restoreGState()

    // Hairline rim so the tile separates from dark docks and wallpapers.
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(rgb(0xD6E2EE, detail == 0 ? 0.28 : 0.18))
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
