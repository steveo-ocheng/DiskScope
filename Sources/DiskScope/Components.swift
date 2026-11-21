import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Finder-style file icons, cached by type so scrolling huge folders stays cheap.
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for node: FileNode) -> NSImage {
        let ext = (node.name as NSString).pathExtension.lowercased()
        if node.isSymlink { return cached("link") { NSWorkspace.shared.icon(for: .aliasFile) } }
        if node.isDirectory {
            // conformingTo: .directory — the plain lookup only finds types under public.data, so it
            // would never recognise .app or other bundles.
            if !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory), type.conforms(to: .package) {
                // Apps get their own icon (few of them); other bundles use the type icon.
                if type.conforms(to: .application) {
                    return cached("app:" + node.path) { NSWorkspace.shared.icon(forFile: node.path) }
                }
                return cached("pkg:" + ext) { NSWorkspace.shared.icon(for: type) }
            }
            return cached("folder") { NSWorkspace.shared.icon(for: .folder) }
        }
        return cached("f:" + ext) { NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data) }
    }

    static func kind(of node: FileNode) -> String {
        if node.isSymlink { return "Symbolic link" }
        let ext = (node.name as NSString).pathExtension
        if node.isDirectory {
            if let t = UTType(filenameExtension: ext, conformingTo: .directory), t.conforms(to: .package) {
                return t.localizedDescription ?? "Package"
            }
            return "Folder"
        }
        return UTType(filenameExtension: ext)?.localizedDescription ?? "Document"
    }

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let img = cache[key] { return img }
        if cache.count > 2000 { cache.removeAll() }
        let img = make()
        cache[key] = img
        return img
    }
}

struct FileIcon: View {
    let node: FileNode
    var size: CGFloat = 16
    var body: some View {
        Image(nsImage: IconCache.icon(for: node))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// Small horizontal bar showing a share of the parent's size.
struct MiniBar: View {
    let fraction: Double
    var width: CGFloat = 36
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(.tint).frame(width: width * min(max(fraction, 0), 1))
        }
        .frame(width: width, height: 4)
    }
}

struct UsageBar: View {
    let fraction: Double
    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.gradient)
                        .frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 10)
            Text(fraction.formatted(.percent.precision(.fractionLength(1))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

struct CapacityBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(fraction > 0.9 ? Color.red.gradient : Color.accentColor.gradient)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 5)
    }
}

/// Finder's bottom path bar: icon + name crumbs, click to jump.
struct PathBar: View {
    @EnvironmentObject var model: AppModel
    let current: FileNode

    var body: some View {
        let chain: [FileNode] = switch model.viewMode {
        case .list: current.ancestry
        case .columns: current.ancestry + [model.selectedFile].compactMap { $0 }
        // A sunburst selection can be several rings deep, so show its own full path.
        case .sunburst: model.selectedFile?.ancestry ?? current.ancestry
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(chain.enumerated()), id: \.element.id) { i, node in
                    if i > 0 {
                        Image(systemName: "chevron.forward").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    }
                    Button { model.reveal(inBrowser: node) } label: {
                        HStack(spacing: 3) {
                            FileIcon(node: node, size: 14)
                            Text(node.parent == nil ? Self.rootTitle(node) : node.name).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(height: 22)
        }
    }

    static func rootTitle(_ node: FileNode) -> String {
        node.path == "/" ? "/" : (node.path as NSString).lastPathComponent
    }
}

/// Finder-style status bar: "12 items, 1.2 GB on disk, 120 GB available".
struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    let current: FileNode

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Text("\(Format.count(current.children.count)) items")
                Text(", \(Format.bytes(model.size(of: current))) \(model.showApparentSize ? "apparent" : "on disk")")
                Text(" (\(Format.count(current.itemCount)) total)").foregroundStyle(.tertiary)
                if let v = model.volume {
                    Text(", \(Format.bytes(v.available)) available on \(v.name)")
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)

            if let hidden = model.hiddenSpace, hidden.total > 0 {
                HStack {
                    HiddenSpaceButton(space: hidden)
                    Spacer()
                }
            }

            if let root = model.root, root.errorCount > 0 {
                HStack {
                    Spacer()
                    Button { model.openFullDiskAccessSettings() } label: {
                        Label("\(Format.count(root.errorCount)) unreadable", systemImage: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .help("Some items couldn't be read. Click to open Privacy & Security › Full Disk Access, add DiskScope, then rescan.")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}

/// "94 GB not in scan": opens the breakdown of used space the scan couldn't see.
private struct HiddenSpaceButton: View {
    @EnvironmentObject var model: AppModel
    let space: HiddenSpace
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label("\(Format.bytes(space.total)) not in scan", systemImage: "eye.slash")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help("Used space on \(space.volumeName) that isn't in the scanned files. Click for details.")
        .popover(isPresented: $showing, arrowEdge: .top) {
            HiddenSpaceDetails(space: space, onFullDiskAccess: { model.openFullDiskAccessSettings() })
                .padding(16)
                .frame(width: 380)
        }
    }
}

/// Finder's preview pane for a file selected in column view.
struct FilePreview: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: node.path))
                    .resizable()
                    .frame(width: 128, height: 128)
                    .padding(.top, 24)
                VStack(spacing: 2) {
                    Text(node.name).font(.headline).multilineTextAlignment(.center).lineLimit(3)
                    Text("\(IconCache.kind(of: node)) – \(Format.bytes(node.apparentSize))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    row("On disk", Format.bytes(node.diskSize))
                    row("Size", "\(Format.bytes(node.apparentSize)) (\(Format.count(Int(node.apparentSize))) bytes)")
                    if let parent = node.parent {
                        row("Of folder", (Double(model.size(of: node)) / Double(max(model.size(of: parent), 1)))
                            .formatted(.percent.precision(.fractionLength(1))))
                    }
                    if node.modified != .distantPast {
                        row("Modified", node.modified.formatted(date: .abbreviated, time: .shortened))
                    }
                    row("Where", (node.path as NSString).deletingLastPathComponent)
                }
                .font(.caption)
                HStack {
                    Button("Open") { model.open(node, explicit: true) }
                    Button("Show in Finder") { model.revealInFinder([node]) }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }
}
