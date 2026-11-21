import SwiftUI

/// Finder-style sidebar: Locations (every mounted drive) and Favorites. Clicking scans it.
struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var volumes: VolumeStore
    @Environment(\.openWindow) private var openWindow

    private struct Favorite: Identifiable {
        let name: String, icon: String, path: String
        var id: String { path }
    }

    private let favorites: [Favorite] = {
        let home = NSHomeDirectory()
        return [
            Favorite(name: NSUserName(), icon: "house", path: home),
            Favorite(name: "Desktop", icon: "menubar.dock.rectangle", path: home + "/Desktop"),
            Favorite(name: "Documents", icon: "doc", path: home + "/Documents"),
            Favorite(name: "Downloads", icon: "arrow.down.circle", path: home + "/Downloads"),
            Favorite(name: "Applications", icon: "square.grid.2x2", path: "/Applications"),
            Favorite(name: "Library", icon: "books.vertical", path: home + "/Library"),
        ]
    }()

    /// Highlights whichever entry is the root of the current (or in-progress) scan.
    private var selection: Binding<String?> {
        Binding(
            get: { model.phase == .scanning ? model.scanTarget : model.root?.path },
            set: { path in
                guard let path else { return }
                if let root = model.root, root.path == path, model.phase != .scanning {
                    model.navigate(to: root)
                } else {
                    model.scan(path)
                }
            })
    }

    private var otherRoot: String? {
        guard let path = model.root?.path ?? (model.phase == .scanning ? model.scanTarget : nil) else { return nil }
        let listed = Set(volumes.volumes.map(\.path) + favorites.map(\.path))
        return listed.contains(path) ? nil : path
    }

    var body: some View {
        List(selection: selection) {
            Section("Locations") {
                ForEach(volumes.volumes) { v in
                    VolumeRow(volume: v).tag(v.path)
                }
            }
            Section("Favorites") {
                ForEach(favorites) { f in
                    Label(f.name, systemImage: f.icon).tag(f.path)
                }
            }
            if let path = otherRoot {
                Section("Scanned") {
                    Label((path as NSString).lastPathComponent, systemImage: "folder").tag(path)
                        .help(path)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Button { model.chooseFolder() } label: {
                    Label("Scan Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                Button { openWindow(id: "duplicates") } label: {
                    Label("Find Duplicates…", systemImage: "square.on.square")
                }
                .buttonStyle(.borderless)
                Toggle("Stay on one volume", isOn: $model.stayOnDevice)
                    .toggleStyle(.checkbox)
                    .help("Don't descend into other disks mounted inside the scanned folder")
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct VolumeRow: View {
    @EnvironmentObject var model: AppModel
    let volume: Volume

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: volume.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name).lineLimit(1)
                CapacityBar(fraction: volume.usedFraction)
                Text("\(Format.bytes(volume.available)) free of \(Format.bytes(volume.total))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if volume.isEjectable || volume.isRemovable || !volume.isLocal {
                Button { model.eject(volume) } label: { Image(systemName: "eject.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Eject “\(volume.name)”")
            }
        }
        .padding(.vertical, 2)
        .help("\(volume.kind) · \(volume.format) · \(volume.path)")
        .contextMenu {
            Button("Scan “\(volume.name)”") { model.scan(volume) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: volume.path)]) }
            if volume.isEjectable || volume.isRemovable || !volume.isLocal {
                Divider()
                Button("Eject “\(volume.name)”") { model.eject(volume) }
            }
        }
    }
}
