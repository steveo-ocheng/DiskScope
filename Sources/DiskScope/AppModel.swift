import AppKit
import SwiftUI

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Info about the volume holding the scanned tree, shown in the status bar.
struct VolumeSummary {
    let name: String
    let total: Int64
    let available: Int64
}

enum ViewMode: String, CaseIterable {
    case list, columns
}

enum SortKey: String, CaseIterable, Identifiable {
    case size = "Size", name = "Name", items = "Items", modified = "Date Modified"
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case idle, scanning, browsing }

    // Scan state
    @Published var phase: Phase = .idle
    @Published var stats = ScanStats()
    @Published var scanTarget = ""
    @Published var root: FileNode? { didSet { sortCache.removeAll() } }
    @Published var volume: VolumeSummary?
    @Published var stayOnDevice = false

    // Navigation
    @Published private(set) var current: FileNode?
    @Published var selectedFile: FileNode?           // column view: file selected in the last column
    @Published var listSelection = Set<FileNode.ID>() // list view selection
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    private var history: [FileNode] = []
    private var historyIndex = -1

    // Presentation
    @Published var viewMode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .columns {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    @Published var showApparentSize = false {
        didSet { sortCache.removeAll(); if sortKey == .size { setSort(.size) } }
    }
    @Published var sortOrder = [KeyPathComparator(\FileNode.diskSize, order: .reverse)] {
        didSet { sortCache.removeAll() }
    }
    @Published var revision = 0 { didSet { sortCache.removeAll() } } // bumped when the tree mutates

    // Search
    @Published var searchText = ""
    @Published var searchWholeScan = true
    @Published private(set) var searchResults: [FileNode] = []
    @Published private(set) var searchMatchCount = 0
    @Published private(set) var searching = false
    @Published var searchSelection = Set<FileNode.ID>()
    static let searchResultLimit = 1000
    private static let searchCollectLimit = 100_000

    // Dialogs
    @Published var alert: AlertInfo?
    @Published var pendingTrash: [FileNode] = []

    private var scanner: Scanner?
    private var sortCache: [ObjectIdentifier: [FileNode]] = [:]

    // MARK: Sorting

    /// Children in the current sort order, cached until the tree or sort order changes.
    func sortedChildren(of node: FileNode) -> [FileNode] {
        if let cached = sortCache[node.id] { return cached }
        let sorted = node.children.sorted(using: sortOrder)
        sortCache[node.id] = sorted
        return sorted
    }

    var sortKey: SortKey? {
        guard let kp = sortOrder.first?.keyPath else { return nil }
        if kp == \FileNode.diskSize || kp == \FileNode.apparentSize { return .size }
        if kp == \FileNode.name { return .name }
        if kp == \FileNode.itemCount { return .items }
        if kp == \FileNode.modified { return .modified }
        return nil
    }

    func setSort(_ key: SortKey) {
        switch key {
        case .size:
            sortOrder = [KeyPathComparator(showApparentSize ? \FileNode.apparentSize : \FileNode.diskSize, order: .reverse)]
        case .name: sortOrder = [KeyPathComparator(\FileNode.name)]
        case .items: sortOrder = [KeyPathComparator(\FileNode.itemCount, order: .reverse)]
        case .modified: sortOrder = [KeyPathComparator(\FileNode.modified, order: .reverse)]
        }
    }

    func size(of node: FileNode) -> Int64 { showApparentSize ? node.apparentSize : node.diskSize }

    // MARK: Scanning

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Scan"
        panel.message = "Choose a folder or disk to scan"
        if panel.runModal() == .OK, let url = panel.url { scan(url.path) }
    }

    func scan(_ volume: Volume) { scan(volume.path) }

    func scan(_ rawPath: String) {
        let path = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            alert = AlertInfo(title: "Can't scan “\((path as NSString).lastPathComponent)”",
                              message: "\(path) is not a folder or no longer exists.")
            return
        }
        // Free the previous tree before building a new one; large scans can hold millions of nodes.
        resetTree()
        startScan(path) { [weak self] newRoot in
            guard let self else { return }
            self.root = newRoot
            self.navigate(to: newRoot)
            self.refreshVolume()
        }
    }

    /// Rescan the folder currently shown (like ncdu's `r`) and splice it into the tree.
    func rescanCurrent() {
        guard let old = current else { return }
        guard let parent = old.parent else { scan(old.path); return }
        startScan(old.path) { [weak self] fresh in
            guard let self, old.parent === parent else { return } // folder was trashed meanwhile
            self.purgeReferences(into: old)
            fresh.name = old.name // scanner names its root by full path
            parent.replace(old, with: fresh)
            self.navigate(to: fresh)
            self.refreshVolume()
        }
    }

    private func startScan(_ path: String, completion: @escaping @MainActor (FileNode) -> Void) {
        scanner?.cancel()
        let scanner = Scanner()
        self.scanner = scanner
        scanTarget = path
        stats = ScanStats(currentPath: path)
        phase = .scanning
        let stayOnDevice = self.stayOnDevice

        let report: @Sendable (ScanStats) -> Void = { [weak self] s in
            Task { @MainActor in
                guard let self, self.scanner === scanner else { return }
                self.stats = s
            }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<FileNode?, Error>
            do {
                outcome = .success(try scanner.scan(path: path, stayOnDevice: stayOnDevice, progress: report))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self, self.scanner === scanner else { return }
                self.scanner = nil
                switch outcome {
                case .success(let node?):
                    completion(node)
                case .success(nil):
                    break // cancelled
                case .failure(let error):
                    self.alert = AlertInfo(title: "Scan failed", message: error.localizedDescription)
                }
                self.phase = (self.root == nil) ? .idle : .browsing
                self.revision += 1
            }
        }
    }

    func cancelScan() {
        scanner?.cancel()
        scanner = nil
        phase = (root == nil) ? .idle : .browsing
    }

    func closeScan() {
        cancelScan()
        resetTree()
        phase = .idle
    }

    private func resetTree() {
        root = nil
        current = nil
        selectedFile = nil
        listSelection = []
        history = []
        historyIndex = -1
        searchText = ""
        searchResults = []
        volume = nil
        updateHistoryFlags()
    }

    private func refreshVolume() {
        guard let path = root?.path else { volume = nil; return }
        Task.detached(priority: .utility) {
            let v = Volume(url: URL(fileURLWithPath: path))
            await MainActor.run { [weak self] in
                self?.volume = v.map { VolumeSummary(name: $0.name, total: $0.total, available: $0.available) }
            }
        }
    }

    // MARK: Navigation

    /// Show `node`'s contents; optionally select a file inside it (column view).
    func navigate(to node: FileNode, selecting file: FileNode? = nil, record: Bool = true) {
        if node !== current {
            if record {
                history = Array(history.prefix(historyIndex + 1))
                history.append(node)
                if history.count > 200 { history.removeFirst(history.count - 200) }
                historyIndex = history.count - 1
            }
            current = node
            listSelection = []
        }
        selectedFile = file
        updateHistoryFlags()
    }

    /// Column view: the user picked `node` in the column listing `parent`.
    func select(_ node: FileNode, in parent: FileNode) {
        if node.isDirectory { navigate(to: node) } else { navigate(to: parent, selecting: node) }
    }

    /// Jump to an item from anywhere (search results, path bar): show its folder with it selected.
    func reveal(inBrowser node: FileNode) {
        searchText = ""
        if node.isDirectory {
            navigate(to: node)
        } else if let parent = node.parent {
            navigate(to: parent, selecting: node)
            listSelection = [node.id]
        }
    }

    func open(_ node: FileNode) {
        if node.isDirectory {
            navigate(to: node)
        } else if !node.isSymlink {
            NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
        } else {
            revealInFinder([node])
        }
    }

    func goUp() {
        guard let current else { return }
        if selectedFile != nil, viewMode == .columns { selectedFile = nil; return }
        if let parent = current.parent { navigate(to: parent, selecting: nil) }
    }

    func goBack() { stepHistory(-1) }
    func goForward() { stepHistory(+1) }

    private func stepHistory(_ delta: Int) {
        var i = historyIndex + delta
        // Skip entries that were trashed or replaced since we visited them.
        while i >= 0, i < history.count, !isAttached(history[i]) { history.remove(at: i); if delta < 0 { i -= 1 } }
        guard i >= 0, i < history.count else { updateHistoryFlags(); return }
        historyIndex = i
        current = history[i]
        selectedFile = nil
        listSelection = []
        updateHistoryFlags()
    }

    private func updateHistoryFlags() {
        canGoBack = historyIndex > 0
        canGoForward = historyIndex >= 0 && historyIndex < history.count - 1
    }

    private func isAttached(_ node: FileNode) -> Bool {
        var n: FileNode? = node
        while let c = n { if c === root { return true }; n = c.parent }
        return false
    }

    // MARK: Search

    /// Searches names in the scanned tree in chunks so the UI stays responsive. Cancelled by the caller's task.
    func performSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let base = searchWholeScan ? root : current else {
            searchResults = []; searchMatchCount = 0; searching = false
            return
        }
        searching = true
        defer { searching = false }
        var matches: [FileNode] = []
        var total = 0
        var stack: [FileNode] = base.children
        var visited = 0
        while let node = stack.popLast() {
            if node.name.localizedStandardContains(query) {
                total += 1
                if matches.count < Self.searchCollectLimit { matches.append(node) }
            }
            if node.isDirectory { stack.append(contentsOf: node.children) }
            visited += 1
            if visited % 20_000 == 0 {
                await Task.yield()
                if Task.isCancelled { return }
            }
        }
        matches.sort { size(of: $0) > size(of: $1) }
        searchResults = Array(matches.prefix(Self.searchResultLimit))
        searchMatchCount = total
        searchSelection = []
    }

    // MARK: Selection-based actions

    /// The items toolbar/menu actions apply to, depending on the visible view.
    var actionTargets: [FileNode] {
        if !searchText.isEmpty { return searchResults.filter { searchSelection.contains($0.id) } }
        guard let current else { return [] }
        switch viewMode {
        case .list:
            return current.children.filter { listSelection.contains($0.id) }
        case .columns:
            if let f = selectedFile { return [f] }
            return current.parent == nil ? [] : [current]
        }
    }

    func revealInFinder(_ nodes: [FileNode]) {
        NSWorkspace.shared.activateFileViewerSelecting(nodes.map { URL(fileURLWithPath: $0.path) })
    }

    func copyPaths(_ nodes: [FileNode]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(nodes.map(\.path).joined(separator: "\n"), forType: .string)
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func eject(_ volume: Volume) {
        if root.map({ $0.path == volume.path || $0.path.hasPrefix(volume.path + "/") }) ?? false { closeScan() }
        if phase == .scanning, scanTarget == volume.path || scanTarget.hasPrefix(volume.path + "/") { closeScan() }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volume.path))
        } catch {
            alert = AlertInfo(title: "Couldn't eject “\(volume.name)”", message: error.localizedDescription)
        }
    }

    // MARK: Trash

    func requestTrash(_ nodes: [FileNode]) {
        let candidates = nodes.filter { $0.parent != nil }
        guard !candidates.isEmpty else { return }
        let blocked = candidates.filter { TrashGuard.isProtected($0.path) }
        if !blocked.isEmpty {
            alert = AlertInfo(title: "Protected item",
                              message: "DiskScope won't move system or top-level folders to the Trash:\n"
                                + blocked.map(\.path).joined(separator: "\n"))
            return
        }
        pendingTrash = candidates
    }

    func confirmTrash() {
        var failures: [String] = []
        for node in pendingTrash {
            // Re-check right before acting: the item may have been changed or replaced since the scan.
            switch TrashGuard.verify(node) {
            case .gone:
                detach(node)
                continue
            case .changedKind:
                failures.append("\(node.name): it changed since the scan. Rescan and try again.")
                continue
            case .ok:
                break
            }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: nil)
                detach(node)
            } catch {
                failures.append("\(node.name): \(error.localizedDescription)")
            }
        }
        pendingTrash = []
        revision += 1
        refreshVolume()
        if !failures.isEmpty {
            alert = AlertInfo(title: "Couldn't move to Trash", message: failures.joined(separator: "\n"))
        }
    }

    /// Remove a node from the tree and move the view off it if it was being shown.
    private func detach(_ node: FileNode) {
        guard let parent = node.parent else { return }
        if let current, Self.isInside(current, node) {
            navigate(to: parent, record: false)
        }
        listSelection.remove(node.id)
        purgeReferences(into: node)
        parent.remove(node)
    }

    private static func isInside(_ node: FileNode, _ subtree: FileNode) -> Bool {
        var n: FileNode? = node
        while let c = n { if c === subtree { return true }; n = c.parent }
        return false
    }

    /// Before a subtree is dropped from the tree, forget every node we hold inside it.
    /// FileNode.parent is unowned, so a retained node whose ancestors were freed must never be touched.
    /// Must run while the subtree is still attached (parent links intact).
    private func purgeReferences(into subtree: FileNode) {
        var kept: [FileNode] = []
        var newIndex = -1
        for (i, n) in history.enumerated() where !Self.isInside(n, subtree) {
            kept.append(n)
            if i <= historyIndex { newIndex = kept.count - 1 }
        }
        history = kept
        historyIndex = newIndex
        searchResults.removeAll { Self.isInside($0, subtree) }
        searchSelection = []
        if let f = selectedFile, Self.isInside(f, subtree) { selectedFile = nil }
        sortCache.removeAll()
        updateHistoryFlags()
    }
}

/// Safety checks before anything is moved to the Trash.
enum TrashGuard {
    enum Check { case ok, gone, changedKind }

    private static let home = NSHomeDirectory()

    private static let protectedPaths: Set<String> = {
        var p: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/private",
            "/bin", "/sbin", "/usr", "/etc", "/var", "/tmp", "/opt", "/cores", "/dev",
            "/private/etc", "/private/var", "/private/tmp", "/usr/local", "/Users/Shared",
        ]
        p.insert(home)
        for sub in ["Library", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications"] {
            p.insert((home as NSString).appendingPathComponent(sub))
        }
        return p
    }()

    private static let protectedPrefixes = ["/System/", "/bin/", "/sbin/", "/usr/", "/private/var/db/", "/Library/Apple/"]

    static func isProtected(_ path: String) -> Bool {
        if protectedPaths.contains(path) { return true }
        if path.hasPrefix("/usr/local/") { return false }
        if protectedPrefixes.contains(where: { path.hasPrefix($0) }) { return true }
        // Never trash a whole mounted volume.
        if let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isVolumeKey]), v.isVolume == true {
            return true
        }
        return false
    }

    /// lstat (never following symlinks) and confirm the item is still the same kind of thing we scanned.
    static func verify(_ node: FileNode) -> Check {
        var st = stat()
        guard lstat(node.path, &st) == 0 else { return .gone }
        let type = st.st_mode & S_IFMT
        if node.isDirectory != (type == S_IFDIR) { return .changedKind }
        if node.isSymlink != (type == S_IFLNK) { return .changedKind }
        return .ok
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    static func count(_ n: Int) -> String {
        n.formatted(.number)
    }
}
