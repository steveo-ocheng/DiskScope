import AppKit

/// A mounted, user-visible volume (boot disk, external drives, USB sticks, network shares, disk images).
struct Volume: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let total: Int64
    let available: Int64
    let isRoot: Bool
    let isRemovable: Bool
    let isEjectable: Bool
    let isInternal: Bool
    let isLocal: Bool
    let format: String

    var id: String { path }
    var used: Int64 { max(total - available, 0) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    var symbol: String {
        if !isLocal { return "server.rack" }
        if isRoot || (isInternal && !isEjectable) { return "internaldrive.fill" }
        if isRemovable || isEjectable { return "externaldrive.fill" }
        return "externaldrive.fill"
    }

    var kind: String {
        if isRoot { return "Startup Disk" }
        if !isLocal { return "Network" }
        if isInternal && !isEjectable { return "Internal" }
        return "External"
    }

    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
        .volumeIsLocalKey, .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey,
    ]

    /// Reads volume info for the volume containing `path` (or the volume mounted at it).
    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: Set(Self.keys)) else { return nil }
        if v.volumeIsBrowsable == false { return nil }
        path = url.standardizedFileURL.path
        isRoot = path == "/"
        name = v.volumeLocalizedName ?? url.lastPathComponent
        total = Int64(v.volumeTotalCapacity ?? 0)
        // "Important usage" counts purgeable space as free, matching Finder. Some network
        // filesystems report 0 for it, so fall back to the raw figure.
        let important = v.volumeAvailableCapacityForImportantUsage ?? 0
        available = important > 0 ? important : Int64(v.volumeAvailableCapacity ?? 0)
        isRemovable = v.volumeIsRemovable ?? false
        isEjectable = v.volumeIsEjectable ?? false
        isInternal = v.volumeIsInternal ?? false
        isLocal = v.volumeIsLocal ?? true
        format = v.volumeLocalizedFormatDescription ?? ""
    }

    static func mounted() -> [Volume] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(Volume.init(url:))
            .sorted { ($0.isRoot ? 0 : 1, $0.name.localizedLowercase) < ($1.isRoot ? 0 : 1, $1.name.localizedLowercase) }
    }
}

/// Keeps the list of mounted volumes current as disks are attached and ejected.
@MainActor
final class VolumeStore: ObservableObject {
    @Published private(set) var volumes: [Volume] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    /// Querying network volumes can block, so do it off the main thread.
    func refresh() {
        Task.detached(priority: .utility) {
            let list = Volume.mounted()
            await MainActor.run { [weak self] in self?.volumes = list }
        }
    }
}
