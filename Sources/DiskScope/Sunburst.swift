import AppKit
import SwiftUI

// MARK: - Layout

/// One ring slice of the sunburst chart.
struct SunburstSegment {
    enum Kind: Equatable {
        case item           // a file or folder
        case smaller(Int)   // this many items too thin to draw, merged
        case hidden         // used space that isn't in the scan (whole-disk scans)
    }

    /// Weak: Trash can detach this subtree before the layout is rebuilt, and FileNode.parent is
    /// unowned, so a node that outlives its ancestors must never be reachable from here.
    weak var node: FileNode?
    /// The folder the item (or merged items) lives in. Weak for the same reason.
    weak var parent: FileNode?
    let kind: Kind
    let depth: Int          // 1 = the ring next to the center
    let start: Double       // fraction of the circle, 0 = top, clockwise
    let end: Double
    let bytes: Int64
    let colorIndex: Int     // index of the top-level slice it descends from (-1: none)
    let isDirectory: Bool
    let name: String        // display-safe

    var span: Double { end - start }
    var mid: Double { (start + end) / 2 }
}

enum SunburstHit: Equatable {
    case center
    case segment(Int)
    case none
}

/// Where the rings are drawn inside a view of a given size.
struct SunburstGeometry: Equatable {
    let center: CGPoint
    let radius: CGFloat     // outer edge of the outermost ring
    let inner: CGFloat      // radius of the center disc
    let ring: CGFloat       // width of one ring
    let depth: Int

    init(size: CGSize, depth: Int, padding: CGFloat = 12) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        radius = max(min(size.width, size.height) / 2 - padding, 1)
        inner = radius * 0.22
        self.depth = max(depth, 1)
        ring = (radius - inner) / CGFloat(self.depth)
    }

    func innerRadius(depth d: Int) -> CGFloat { inner + CGFloat(d - 1) * ring }
    func outerRadius(depth d: Int) -> CGFloat { inner + CGFloat(d) * ring }

    /// Point on the circle of radius `r` at `fraction` of a turn (0 = top, clockwise).
    func point(fraction: Double, radius r: CGFloat) -> CGPoint {
        let a = fraction * 2 * .pi - .pi / 2
        return CGPoint(x: center.x + r * CGFloat(cos(a)), y: center.y + r * CGFloat(sin(a)))
    }
}

enum SunburstLayout {
    static let defaultMaxDepth = 5
    /// Merged "smaller items" slices thinner than this aren't worth drawing.
    static let minimumDrawnSpan = 0.0005

    /// Lays out `center`'s subtree as rings. Angles are proportional to `size` relative to
    /// `size(center) + hidden`. Rings are filled breadth-first, so when `maxSegments` is hit the
    /// outer rings lose detail first. Per folder only children at least `minSpan` wide are sorted
    /// and drawn (at most 1/minSpan of them); the rest become one `.smaller` slice, so folders
    /// with huge numbers of children stay cheap.
    static func make(center: FileNode, size: (FileNode) -> Int64, hidden: Int64 = 0,
                     maxDepth: Int = defaultMaxDepth, minSpan: Double = 0.0025,
                     maxSegments: Int = 6000) -> [SunburstSegment] {
        let hidden = max(hidden, 0)
        let centerSize = max(size(center), 0)
        let total = Double(centerSize) + Double(hidden)
        guard total > 0, maxDepth > 0, maxSegments > 0 else { return [] }
        let centerEnd = Double(centerSize) / total
        let slots = hidden > 0 ? maxSegments - 1 : maxSegments // keep room for the hidden slice

        var segments: [SunburstSegment] = []
        segments.reserveCapacity(min(slots, 2048))

        struct Job { let folder: FileNode; let depth: Int; let start: Double; let end: Double; let color: Int? }
        var queue = [Job(folder: center, depth: 1, start: 0, end: centerEnd, color: nil)]
        var next = 0
        let threshold = minSpan * total

        while next < queue.count, segments.count < slots {
            let job = queue[next]
            next += 1
            guard job.depth <= maxDepth else { continue }

            var big: [(node: FileNode, bytes: Int64)] = []
            var smallCount = 0
            var smallBytes: Int64 = 0
            for child in job.folder.children {
                let b = size(child)
                guard b > 0 else { continue }
                if Double(b) >= threshold { big.append((child, b)) } else { smallCount += 1; smallBytes += b }
            }
            big.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.node.name < $1.node.name }

            var cursor = job.start
            for (i, entry) in big.enumerated() {
                // Leave one slot for the merged slice if anything is left over.
                let leftover = i < big.count - 1 || smallCount > 0
                if segments.count >= slots - (leftover ? 1 : 0) {
                    for rest in big[i...] { smallCount += 1; smallBytes += rest.bytes }
                    break
                }
                let end = min(cursor + Double(entry.bytes) / total, job.end)
                let color = job.color ?? i
                segments.append(SunburstSegment(
                    node: entry.node, parent: job.folder, kind: .item, depth: job.depth,
                    start: cursor, end: end, bytes: entry.bytes, colorIndex: color,
                    isDirectory: entry.node.isDirectory, name: Format.displaySafe(entry.node.name)))
                if entry.node.isDirectory, job.depth < maxDepth, !entry.node.children.isEmpty {
                    queue.append(Job(folder: entry.node, depth: job.depth + 1, start: cursor, end: end, color: color))
                }
                cursor = end
            }

            if smallCount > 0, segments.count < slots {
                let end = min(cursor + Double(smallBytes) / total, job.end)
                if end - cursor > minimumDrawnSpan {
                    segments.append(SunburstSegment(
                        node: nil, parent: job.folder, kind: .smaller(smallCount), depth: job.depth,
                        start: cursor, end: end, bytes: smallBytes, colorIndex: job.color ?? -1,
                        isDirectory: false,
                        name: smallCount == 1 ? "1 smaller item" : "\(Format.count(smallCount)) smaller items"))
                }
            }
        }

        if hidden > 0 {
            segments.append(SunburstSegment(
                node: nil, parent: center, kind: .hidden, depth: 1, start: centerEnd, end: 1,
                bytes: hidden, colorIndex: -1, isDirectory: false, name: "Not in scan"))
        }
        return segments
    }

    static func hitTest(_ segments: [SunburstSegment], point: CGPoint, geometry g: SunburstGeometry) -> SunburstHit {
        let dx = Double(point.x - g.center.x), dy = Double(point.y - g.center.y)
        let r = (dx * dx + dy * dy).squareRoot()
        if r < Double(g.inner) { return .center }
        guard r < Double(g.radius), g.ring > 0 else { return .none }
        let depth = Int((r - Double(g.inner)) / Double(g.ring)) + 1
        var a = atan2(dx, -dy) / (2 * .pi)
        if a < 0 { a += 1 }
        if let i = segments.firstIndex(where: { $0.depth == depth && a >= $0.start && a < $0.end }) {
            return .segment(i)
        }
        return .none
    }

    /// The annular sector for a segment.
    static func path(for s: SunburstSegment, geometry g: SunburstGeometry) -> Path {
        let r0 = g.innerRadius(depth: s.depth), r1 = g.outerRadius(depth: s.depth)
        let a0 = Angle.radians(s.start * 2 * .pi - .pi / 2)
        let delta = Angle.radians(s.span * 2 * .pi)
        var p = Path()
        p.addRelativeArc(center: g.center, radius: r1, startAngle: a0, delta: delta)
        p.addRelativeArc(center: g.center, radius: r0, startAngle: a0 + delta, delta: -delta)
        p.closeSubpath()
        return p
    }
}

enum SunburstPalette {
    static func color(for s: SunburstSegment, dark: Bool, highlighted: Bool = false) -> Color {
        switch s.kind {
        case .hidden:
            return Color(white: dark ? (highlighted ? 0.36 : 0.26) : (highlighted ? 0.62 : 0.52))
        case .smaller:
            return Color(white: dark ? (highlighted ? 0.50 : 0.40) : (highlighted ? 0.86 : 0.79))
        case .item:
            let hue = (0.58 + Double(max(s.colorIndex, 0)) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
            let d = Double(s.depth - 1)
            var sat = max(0.22, 0.66 - d * 0.09)
            var bri = dark ? min(0.92, 0.66 + d * 0.05) : min(0.97, 0.80 + d * 0.035)
            if !s.isDirectory { sat *= 0.72; bri = min(1, bri + 0.03) }
            if highlighted { sat = min(1, sat + 0.15); bri = min(1, bri + 0.12) }
            return Color(hue: hue, saturation: sat, brightness: bri)
        }
    }
}

// MARK: - View

/// "Visual map": the current folder as concentric rings, one ring per level, angle ∝ size.
struct SunburstView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    let current: FileNode

    @State private var segments: [SunburstSegment] = []
    @State private var depthPresent = 1
    @State private var layoutVersion = 0
    @State private var hovered: SunburstHit = .none
    @State private var legendHover: Int?
    @State private var menuIndex: Int?          // last hovered slice, kept for the context menu
    @State private var showHiddenInfo = false

    private struct LayoutKey: Equatable {
        let center: ObjectIdentifier
        let revision: Int
        let apparent: Bool
        let hidden: Int64
    }

    /// The "not in scan" slice is only meaningful at the root of a whole-disk scan, in disk usage.
    private var hiddenBytes: Int64 {
        guard current === model.root, !model.showApparentSize, let h = model.hiddenSpace, h.total > 0 else { return 0 }
        return h.total
    }

    private var total: Int64 { model.size(of: current) + hiddenBytes }

    var body: some View {
        let key = LayoutKey(center: ObjectIdentifier(current), revision: model.revision,
                            apparent: model.showApparentSize, hidden: hiddenBytes)
        HStack(spacing: 0) {
            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            SunburstSidePanel(current: current, segments: segments, total: total,
                              dark: colorScheme == .dark, highlighted: highlightedIndex,
                              hover: $legendHover, activate: activate)
                .frame(width: 260)
        }
        .onChange(of: key, initial: true) { rebuild() }
    }

    private var hoveredIndex: Int? {
        if case .segment(let i) = hovered { return i }
        return nil
    }

    private var highlightedIndex: Int? { legendHover ?? hoveredIndex }

    private func rebuild() {
        let apparent = model.showApparentSize
        segments = SunburstLayout.make(center: current, size: { apparent ? $0.apparentSize : $0.diskSize },
                                       hidden: hiddenBytes)
        depthPresent = max(segments.map(\.depth).max() ?? 1, 1)
        layoutVersion &+= 1
        hovered = .none
        legendHover = nil
        menuIndex = nil
    }

    // MARK: Chart

    private var chart: some View {
        GeometryReader { geo in
            let g = SunburstGeometry(size: geo.size, depth: depthPresent)
            let dark = colorScheme == .dark
            ZStack {
                SunburstBaseLayer(segments: segments, version: layoutVersion, geometry: g, dark: dark)
                    .equatable()
                SunburstHighlightLayer(segments: segments, geometry: g, dark: dark,
                                       highlighted: highlightedIndex,
                                       selected: selectedIndex,
                                       centerHovered: hovered == .center && current.parent != nil)
                centerLabel(g)
                if segments.isEmpty {
                    Text(current.errorCount > 0 && current.itemCount == 0 ? "Can't read this folder" : "Nothing to show")
                        .font(.callout).foregroundStyle(.tertiary)
                        .offset(y: g.inner + 24)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    let hit = SunburstLayout.hitTest(segments, point: p, geometry: g)
                    if hit != hovered { hovered = hit }
                    if case .segment(let i) = hit { menuIndex = i }
                case .ended:
                    if hovered != .none { hovered = .none }
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                activate(SunburstLayout.hitTest(segments, point: location, geometry: g))
            }
            .contextMenu {
                if let i = menuIndex, segments.indices.contains(i), segments[i].kind == .item,
                   let node = segments[i].node {
                    ItemMenu(nodes: [node])
                }
            }
            .popover(isPresented: $showHiddenInfo, attachmentAnchor: .point(hiddenAnchor(g, size: geo.size)),
                     arrowEdge: .trailing) {
                if let space = model.hiddenSpace {
                    HiddenSpaceDetails(space: space) { model.openFullDiskAccessSettings() }
                        .padding(16)
                        .frame(width: 380)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sunburst chart of \(Format.displaySafe(chartTitle)), \(Format.bytes(model.size(of: current)))")
            .accessibilityChildren {
                ForEach(segments.indices.filter { segments[$0].depth == 1 }, id: \.self) { i in
                    Button("\(segments[i].name), \(Format.bytes(segments[i].bytes))") { activate(.segment(i)) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            Text(current.parent == nil ? "Click a ring to open it" : "Click a ring to open it · click the center to go up")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 6)
                .allowsHitTesting(false)
        }
    }

    private var chartTitle: String { current.parent == nil ? PathBar.rootTitle(current) : current.name }

    private var selectedIndex: Int? {
        guard let f = model.selectedFile else { return nil }
        return segments.firstIndex { $0.node === f }
    }

    private func hiddenAnchor(_ g: SunburstGeometry, size: CGSize) -> UnitPoint {
        guard let s = segments.last, s.kind == .hidden, size.width > 0, size.height > 0 else { return .center }
        let p = g.point(fraction: s.mid, radius: g.outerRadius(depth: 1))
        return UnitPoint(x: p.x / size.width, y: p.y / size.height)
    }

    @ViewBuilder
    private func centerLabel(_ g: SunburstGeometry) -> some View {
        let info = centerInfo
        VStack(spacing: 2) {
            Text(info.title)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(info.size)
                .font(.callout.monospacedDigit())
            if let sub = info.subtitle {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .minimumScaleFactor(0.6)
        .frame(width: max(g.inner * 1.7, 40))
        .position(g.center)
        .allowsHitTesting(false)
    }

    private var centerInfo: (title: String, size: String, subtitle: String?) {
        let all = Double(max(total, 1))
        if let i = highlightedIndex, segments.indices.contains(i) {
            let s = segments[i]
            let pct = (Double(s.bytes) / all).formatted(.percent.precision(.fractionLength(1)))
            switch s.kind {
            case .hidden: return (s.name, Format.bytes(s.bytes), "Click for details")
            default: return (s.name, Format.bytes(s.bytes), pct)
            }
        }
        if hovered == .center, let parent = current.parent {
            return ("Go up", parent.parent == nil ? PathBar.rootTitle(parent) : Format.displaySafe(parent.name), nil)
        }
        return (Format.displaySafe(chartTitle), Format.bytes(model.size(of: current)),
                hiddenBytes > 0 ? "+ \(Format.bytes(hiddenBytes)) not in scan" : nil)
    }

    // MARK: Actions

    private func activate(_ hit: SunburstHit) {
        switch hit {
        case .center:
            if let parent = current.parent { model.navigate(to: parent) }
        case .segment(let i):
            guard segments.indices.contains(i) else { return }
            let s = segments[i]
            switch s.kind {
            case .item:
                guard let node = s.node else { return }
                if node.isDirectory { model.navigate(to: node) } else { model.navigate(to: current, selecting: node) }
            case .smaller:
                if let folder = s.parent, folder !== current { model.navigate(to: folder) }
            case .hidden:
                showHiddenInfo = true
            }
        case .none:
            break
        }
    }
}

/// All slices. Equatable on the layout version so hovering never redraws thousands of paths.
private struct SunburstBaseLayer: View, Equatable {
    let segments: [SunburstSegment]
    let version: Int
    let geometry: SunburstGeometry
    let dark: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.version == b.version && a.geometry == b.geometry && a.dark == b.dark
    }

    var body: some View {
        Canvas { ctx, _ in
            let g = geometry
            let separator = Color(nsColor: .windowBackgroundColor)
            let disc = Path(ellipseIn: CGRect(x: g.center.x - g.inner, y: g.center.y - g.inner,
                                              width: g.inner * 2, height: g.inner * 2))
            ctx.fill(disc, with: .color(Color.secondary.opacity(dark ? 0.16 : 0.08)))
            for s in segments {
                let p = SunburstLayout.path(for: s, geometry: g)
                ctx.fill(p, with: .color(SunburstPalette.color(for: s, dark: dark)))
                if s.kind == .hidden { hatch(&ctx, p, color: Color.white.opacity(dark ? 0.10 : 0.22)) }
                ctx.stroke(p, with: .color(separator), lineWidth: 1)
            }
        }
    }

    private func hatch(_ ctx: inout GraphicsContext, _ path: Path, color: Color) {
        ctx.drawLayer { layer in
            layer.clip(to: path)
            let b = path.boundingRect
            var lines = Path()
            var x = b.minX - b.height
            while x < b.maxX {
                lines.move(to: CGPoint(x: x, y: b.maxY))
                lines.addLine(to: CGPoint(x: x + b.height, y: b.minY))
                x += 7
            }
            layer.stroke(lines, with: .color(color), lineWidth: 1.5)
        }
    }
}

/// Just the hovered / selected slices and the center's hover tint.
private struct SunburstHighlightLayer: View {
    let segments: [SunburstSegment]
    let geometry: SunburstGeometry
    let dark: Bool
    let highlighted: Int?
    let selected: Int?
    let centerHovered: Bool

    var body: some View {
        Canvas { ctx, _ in
            let g = geometry
            if centerHovered {
                let disc = Path(ellipseIn: CGRect(x: g.center.x - g.inner, y: g.center.y - g.inner,
                                                  width: g.inner * 2, height: g.inner * 2))
                ctx.fill(disc, with: .color(Color.accentColor.opacity(0.18)))
            }
            if let i = selected, segments.indices.contains(i) {
                let p = SunburstLayout.path(for: segments[i], geometry: g)
                ctx.stroke(p, with: .color(.accentColor), lineWidth: 2.5)
            }
            if let i = highlighted, segments.indices.contains(i) {
                let s = segments[i]
                let p = SunburstLayout.path(for: s, geometry: g)
                ctx.fill(p, with: .color(SunburstPalette.color(for: s, dark: dark, highlighted: true)))
                ctx.stroke(p, with: .color(Color.primary.opacity(0.75)), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Side panel

private struct SunburstSidePanel: View {
    @EnvironmentObject var model: AppModel
    let current: FileNode
    let segments: [SunburstSegment]
    let total: Int64
    let dark: Bool
    let highlighted: Int?
    @Binding var hover: Int?
    let activate: (SunburstHit) -> Void

    var body: some View {
        let rows = segments.indices.filter { segments[$0].depth == 1 }
        VStack(alignment: .leading, spacing: 0) {
            Text("Largest Items")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows, id: \.self) { i in
                        legendRow(i)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            if let file = model.selectedFile {
                Divider()
                SunburstFileDetails(node: file)
                    .padding(12)
            }
        }
    }

    private func legendRow(_ i: Int) -> some View {
        let s = segments[i]
        let fraction = Double(s.bytes) / Double(max(total, 1))
        return Button { activate(.segment(i)) } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(SunburstPalette.color(for: s, dark: dark))
                    .frame(width: 10, height: 10)
                if let node = s.node {
                    FileIcon(node: node, size: 16)
                } else {
                    Image(systemName: s.kind == .hidden ? "eye.slash" : "ellipsis.circle")
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.secondary)
                }
                Text(s.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                MiniBar(fraction: fraction, width: 28)
                Text(Format.bytes(s.bytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(highlighted == i ? Color.accentColor.opacity(0.15) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hover = i } else if hover == i { hover = nil }
        }
        .help(s.kind == .hidden ? "Used space this scan didn't find in files. Click for details."
              : "\(s.name) — \(fraction.formatted(.percent.precision(.fractionLength(1))))")
        .contextMenu {
            if let node = s.node { ItemMenu(nodes: [node]) }
        }
    }
}

private struct SunburstFileDetails: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                FileIcon(node: node, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.displaySafe(node.name)).font(.headline).lineLimit(2)
                    Text(IconCache.kind(of: node)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow {
                    Text("On disk").foregroundStyle(.secondary)
                    Text(Format.bytes(node.diskSize))
                }
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    Text(Format.bytes(node.apparentSize))
                }
                if node.modified != .distantPast {
                    GridRow {
                        Text("Modified").foregroundStyle(.secondary)
                        Text(node.modified.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            .font(.caption)
            HStack(spacing: 6) {
                Button("Open") { model.open(node, explicit: true) }
                Button("Show in Finder") { model.revealInFinder([node]) }
                Button("Trash…") { model.requestTrash([node]) }
                    .help("Move to Trash…")
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Hidden space breakdown

/// Explains used space a whole-disk scan didn't find in files. Shown from the sunburst's
/// "Not in scan" slice and reusable elsewhere (e.g. a status-bar popover).
struct HiddenSpaceDetails: View {
    let space: HiddenSpace
    /// Offered when some items couldn't be read; opens Full Disk Access settings.
    var onFullDiskAccess: (() -> Void)? = nil

    private static let scannedColor = Color.accentColor
    private static let volumesColor = Color.purple
    private static let invisibleColor = Color.gray

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Space on “\(Format.displaySafe(space.volumeName))”")
                    .font(.headline)
                Text("\(Format.bytes(space.used)) used. \(Format.bytes(space.total)) of it isn't in the files this scan found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            bar

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                row(Self.scannedColor, "Files in this scan", space.scanned)
                ForEach(space.otherVolumes) { part in
                    row(Self.volumesColor, Format.displaySafe(part.name), part.bytes)
                        .help(part.mountPoint)
                }
                row(Self.invisibleColor, "Not visible to the scan", space.invisible)
                GridRow {
                    Color.clear.frame(width: 10, height: 1)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(invisibleReasons, id: \.self) { Text("• " + $0) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .gridCellColumns(2)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if space.unreadable > 0, let onFullDiskAccess {
                Button("Grant Full Disk Access…", action: onFullDiskAccess)
                    .controlSize(.small)
                    .help("Open Privacy & Security › Full Disk Access, add DiskScope, then rescan.")
            }

            if space.purgeable > 0 {
                Text("About \(Format.bytes(space.purgeable)) of the used space is purgeable: macOS frees it automatically when space runs low (local snapshots, caches, iCloud files kept on this Mac).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if space.scannedExceedsUsed {
                Text("The files add up to more than the space they occupy: APFS clones and copies share storage, so they're counted more than once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var invisibleReasons: [String] {
        var reasons: [String] = []
        if space.snapshots > 0 {
            reasons.append(space.snapshots == 1 ? "1 local Time Machine snapshot"
                                                : "\(Format.count(space.snapshots)) local Time Machine snapshots")
        }
        if space.unreadable > 0 {
            reasons.append("\(Format.count(space.unreadable)) items DiskScope couldn't read")
        }
        reasons.append("File system metadata and hidden system files")
        return reasons
    }

    private var bar: some View {
        let used = Double(max(space.used, 1))
        let scanned = min(Double(space.scanned), used)
        let volumes = min(Double(space.otherVolumesTotal), max(used - scanned, 0))
        let invisible = max(used - scanned - volumes, 0)
        return GeometryReader { geo in
            HStack(spacing: 1) {
                Self.scannedColor.frame(width: geo.size.width * scanned / used)
                Self.volumesColor.frame(width: geo.size.width * volumes / used)
                Self.invisibleColor.frame(width: geo.size.width * invisible / used)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private func row(_ color: Color, _ label: String, _ bytes: Int64) -> some View {
        GridRow {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label).lineLimit(1)
            Text(Format.bytes(bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
        }
    }
}
