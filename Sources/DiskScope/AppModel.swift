import AppKit
import UniformTypeIdentifiers
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
    case list, columns, sunburst
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
    /// Whole-disk scans only: used space the scan didn't find in files (see HiddenSpace).
    @Published private(set) var hiddenSpace: HiddenSpace?
    @Published var stayOnDevice = false
    private var rootStayOnDevice = false // the setting the current root was scanned with

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
    @Published var exporting = false
    @Published var pendingTrash: [FileNode] = []

    private var scanner: Scanner?
    private var sortCache: [ObjectIdentifier: [FileNode]] = [:]

    /// Performs the actual move to the Trash. Injectable so tests never touch the user's Trash.
    private let trasher: (URL) throws -> Void

    init(trasher: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.trasher = trasher
    }

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
        let requested = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath).standardizedFileURL.path
        // Canonicalize (resolve symlinks like /tmp → /private/tmp) so every node path is a real,
        // symlink-free path. TrashGuard.verify relies on this to detect paths swapped after the scan.
        var isDir: ObjCBool = false
        guard let path = TrashGuard.realPath(requested),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            alert = AlertInfo(title: "Can't scan “\(Format.displaySafe((requested as NSString).lastPathComponent))”",
                              message: "\(Format.displaySafe(requested)) is not a folder or no longer exists.")
            return
        }
        // Free the previous tree before building a new one; large scans can hold millions of nodes.
        resetTree()
        let stay = stayOnDevice
        startScan(path) { [weak self] newRoot in
            guard let self else { return }
            self.rootStayOnDevice = stay
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
        // scan() blocks for the whole walk, so run it on a GCD thread rather than tying up a
        // thread of Swift's small cooperative pool.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<FileNode?, Error>
            do {
                outcome = .success(try scanner.scan(path: path, stayOnDevice: stayOnDevice, progress: report))
            } catch {
                outcome = .failure(error)
            }
            Task { @MainActor [weak self] in
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
        hiddenSpace = nil
        updateHistoryFlags()
    }

    private func refreshVolume() {
        guard let root else { volume = nil; hiddenSpace = nil; return }
        let path = root.path, scanned = root.diskSize, unreadable = root.errorCount, stay = rootStayOnDevice
        let rootID = ObjectIdentifier(root)
        Task.detached(priority: .utility) {
            let v = Volume(url: URL(fileURLWithPath: path))
            let hidden = HiddenSpace.measure(root: path, scanned: scanned, unreadable: unreadable, stayOnDevice: stay)
            await MainActor.run { [weak self] in
                guard let self, let current = self.root, ObjectIdentifier(current) == rootID else { return }
                self.volume = v.map { VolumeSummary(name: $0.name, total: $0.total, available: $0.available) }
                self.hiddenSpace = hidden
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

    /// Double-click / Return. Folders are browsed; documents open in their default app.
    /// Apps, scripts and executables are never launched implicitly — they're shown in Finder
    /// unless the user explicitly chose "Open" from a menu (`explicit: true`).
    func open(_ node: FileNode, explicit: Bool = false) {
        if node.isDirectory {
            navigate(to: node)
        } else if node.isSymlink || (!explicit && LaunchSafety.isLaunchable(path: node.path)) {
            revealInFinder([node])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
        }
    }

    func goUp() {
        guard let current else { return }
        if selectedFile != nil, viewMode != .list { selectedFile = nil; return }
        if let parent = current.parent { navigate(to: parent, selecting: nil) }
    }

    func goBack() { stepHistory(-1) }
    func goForward() { stepHistory(+1) }

    private func stepHistory(_ delta: Int) {
        // Drop entries that were trashed or replaced since we visited them, keeping the index
        // anchored on the current entry (which may appear more than once, so track by position).
        var kept: [FileNode] = []
        var newIndex = -1
        for (j, node) in history.enumerated() {
            if j == historyIndex {
                kept.append(node)
                newIndex = kept.count - 1
            } else if isAttached(node) {
                kept.append(node)
            }
        }
        history = kept
        historyIndex = newIndex
        let i = historyIndex + delta
        guard historyIndex >= 0, i >= 0, i < history.count else { updateHistoryFlags(); return }
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
        case .columns, .sunburst:
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

    /// The scanned node at `path` (a canonical path inside the scan), if any.
    func node(atPath path: String) -> FileNode? {
        guard let root else { return nil }
        let rootPath = root.path
        if path == rootPath { return root }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var node = root
        for name in path.dropFirst(prefix.count).split(separator: "/") {
            guard let child = node.children.first(where: { $0.name == name }) else { return nil }
            node = child
        }
        return node
    }

    /// Something outside the browser (Find Duplicates) moved `path` to the Trash: drop it from the tree.
    func forgetTrashed(path: String) {
        guard let node = node(atPath: path), node.parent != nil else { return }
        detach(node)
        revision += 1
        refreshVolume()
    }

    // MARK: Trash

    func requestTrash(_ nodes: [FileNode]) {
        let candidates = nodes.filter { $0.parent != nil }
        guard !candidates.isEmpty else { return }
        let blocked = candidates.filter { TrashGuard.isProtected($0.path) }
        if !blocked.isEmpty {
            alert = AlertInfo(title: "Protected item",
                              message: "DiskScope won't move system or top-level folders to the Trash:\n"
                                + blocked.map { Format.displaySafe($0.path) }.joined(separator: "\n"))
            return
        }
        let unreliable = candidates.filter(TrashGuard.isUnreliable)
        if !unreliable.isEmpty {
            alert = AlertInfo(title: "Can't move to Trash",
                              message: "These items couldn't be read reliably during the scan. Use Show in Finder instead:\n"
                                + unreliable.map { Format.displaySafe($0.path) }.joined(separator: "\n"))
            return
        }
        // Drop items already covered by another selected folder (trashing the folder takes them too).
        pendingTrash = candidates.filter { node in
            !candidates.contains { other in other !== node && Self.isInside(node, other) }
        }
    }

    func confirmTrash() {
        var failures: [String] = []
        for node in pendingTrash where node.parent != nil { // skip items detached by an earlier iteration
            let name = Format.displaySafe(node.name)
            // Re-check right before acting: the item may have been changed or replaced since the scan.
            switch TrashGuard.verify(node) {
            case .gone:
                detach(node)
                continue
            case .changedKind, .pathChanged:
                failures.append("\(name): it changed since the scan. Rescan and try again.")
                continue
            case .unreadable(let code):
                failures.append("\(name): \(String(cString: strerror(code)))")
                continue
            case .ok:
                break
            }
            do {
                try trasher(URL(fileURLWithPath: node.path))
                detach(node)
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
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
    enum Check: Equatable {
        case ok
        case gone                // no longer exists
        case changedKind         // file ↔ folder ↔ symlink since the scan
        case pathChanged         // an enclosing folder is now a symlink / was moved
        case unreadable(Int32)   // lstat failed for another reason (errno)
    }

    /// Items whose own entry failed during the scan: a file that couldn't be stat'd, or any item
    /// whose name wasn't valid UTF-8 (its path is lossy, so it could name a different file).
    static func isUnreliable(_ node: FileNode) -> Bool {
        node.errorCount > 0 && (!node.isDirectory || node.name.unicodeScalars.contains("\u{FFFD}"))
    }

    /// realpath(3): absolute path with all symlinks, "." and ".." resolved; nil if it doesn't exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

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

    /// Confirm the item is still what we scanned, at the same real location:
    /// - every enclosing folder still resolves to itself (none was swapped for a symlink), so the
    ///   move can't be redirected elsewhere — scan roots are canonical, so node paths are real paths;
    /// - lstat (never following symlinks) shows the same kind of item.
    /// - for files and links, size and modification time still match the scan, so a different
    ///   file now sitting at the same path is never trashed by mistake.
    static func verify(_ node: FileNode) -> Check {
        let mtime = node.modified == .distantPast ? nil : Int(node.modified.timeIntervalSince1970)
        return verify(path: node.path, isDirectory: node.isDirectory, isSymlink: node.isSymlink,
                      expectedMtime: mtime, expectedSize: node.apparentSize)
    }

    static func verify(path: String, isDirectory: Bool, isSymlink: Bool,
                       expectedMtime: Int? = nil, expectedSize: Int64? = nil) -> Check {
        let parentPath = (path as NSString).deletingLastPathComponent
        guard let realParent = realPath(parentPath) else {
            return errno == ENOENT ? .gone : .unreadable(errno)
        }
        if realParent != parentPath { return .pathChanged }
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT ? .gone : .unreadable(errno) }
        let type = st.st_mode & S_IFMT
        if isDirectory != (type == S_IFDIR) { return .changedKind }
        if isSymlink != (type == S_IFLNK) { return .changedKind }
        // Folder mtimes change whenever Finder writes .DS_Store, so only files/links are compared.
        if !isDirectory {
            if let expectedMtime, UInt32(clamping: Int(st.st_mtimespec.tv_sec)) != UInt32(clamping: expectedMtime) {
                return .changedKind
            }
            // Extra hard links are recorded with size 0 (counted once), so skip the size check for them.
            if let expectedSize, st.st_nlink <= 1, Int64(st.st_size) != expectedSize { return .changedKind }
        }
        return .ok
    }
}

/// Decides when a double-click must not launch something.
enum LaunchSafety {
    private static let launchableExtensions: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "fish", "terminal", "pkg", "mpkg",
        "workflow", "action", "scpt", "scptd", "applescript", "osascript", "jar", "py", "rb", "pl", "php",
        "js", "jxa", "url", "webloc", "inetloc", "fileloc", "prefpane", "saver", "kext", "plugin",
        "dylib", "bundle", "mobileconfig", "dmg", "iso",
    ]

    /// True for apps, scripts, installers, links and anything with an execute bit.
    static func isLaunchable(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if launchableExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext),
           type.conforms(to: .executable) || type.conforms(to: .script) || type.conforms(to: .application) {
            return true
        }
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, (st.st_mode & 0o111) != 0 { return true }
        return false
    }
}

enum Format {
    /// Makes untrusted file names safe to show in prompts: control characters and Unicode
    /// bidi/invisible formatting characters (which can disguise "evil‮txt.app" as "evilppa.txt")
    /// are replaced with a visible "�".
    static func displaySafe(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
                return "\u{FFFD}"
            default:
                return scalar
            }
        }))
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    static func count(_ n: Int) -> String {
        n.formatted(.number)
    }
}
