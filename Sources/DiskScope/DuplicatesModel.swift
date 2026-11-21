import AppKit
import Foundation
import UniformTypeIdentifiers

/// State for the Find Duplicates window: the folders, the run, the results and the removal plan.
///
/// DiskScope never deletes or moves duplicates itself. Each copy is marked Keep or Remove, and the
/// plan is exported as a script (reviewed and run by the user in Terminal) or as CSV.
@MainActor
final class DuplicatesModel: ObservableObject {
    enum Phase: Equatable { case idle, running, done }

    @Published var folderA: String?
    @Published var folderB: String?
    @Published var options = DupOptions()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = DupProgress()
    /// Internal (not private) set so tests can inject results; `load(_:)` also resets the plan.
    @Published var result: DupResult?
    @Published var selection: DupGroup.ID?
    @Published var alert: AlertInfo?
    @Published var showingScript = false

    /// Default choice of which copy to keep; changing it resets every set to the rule.
    @Published var keepRule: KeepRule = .folderA {
        didSet { if let result { removals = keepRule.removals(for: result.groups) } }
    }
    /// Paths of the copies marked Remove. Every set always keeps at least one copy.
    @Published private(set) var removals: Set<String> = []

    private var finder: DuplicateFinder?
    private(set) var runTask: Task<Void, Never>?

    // MARK: Folders

    func folder(_ side: DupSide) -> String? { side == .a ? folderA : folderB }

    func set(_ side: DupSide, path: String?) {
        let normalized = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        if side == .a { folderA = normalized } else { folderB = normalized }
    }

    func choose(_ side: DupSide) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Choose"
        panel.message = side == .a ? "Choose the first folder to compare"
                                   : "Choose the second folder (or leave it empty to search within the first one)"
        if let current = folder(side) { panel.directoryURL = URL(fileURLWithPath: current) }
        if panel.runModal() == .OK, let url = panel.url { set(side, path: url.path) }
    }

    func swapFolders() { (folderA, folderB) = (folderB, folderA) }

    var canStart: Bool { phase != .running && (folderA != nil || folderB != nil) }

    // MARK: Running

    func start() {
        guard canStart else { return }
        // With one folder, search within it (whichever slot it's in).
        let folders = [folderA, folderB].compactMap { $0 }
        let a = folders[0]
        let b = folders.count > 1 ? folders[1] : nil
        let options = self.options

        finder?.cancel()
        let finder = DuplicateFinder()
        self.finder = finder
        phase = .running
        progress = DupProgress()
        result = nil
        removals = []
        selection = nil

        let report: @Sendable (DupProgress) -> Void = { [weak self] p in
            Task { @MainActor in
                guard let self, self.finder === finder else { return }
                self.progress = p
            }
        }
        runTask = Task { [weak self] in
            let outcome: Result<DupResult?, Error> = await withCheckedContinuation { cont in
                // run() blocks for the whole search, so keep it off Swift's cooperative pool.
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: Result { try finder.run(folderA: a, folderB: b, options: options, progress: report) })
                }
            }
            guard let self, self.finder === finder else { return }   // cancelled, or a newer run replaced this one
            self.finder = nil
            switch outcome {
            case .success(let r?):
                self.load(r)
                self.phase = .done
            case .success(nil):
                self.phase = .idle
            case .failure(let error):
                self.alert = AlertInfo(title: "Can't search for duplicates", message: error.localizedDescription)
                self.phase = .idle
            }
        }
    }

    func cancel() {
        finder?.cancel()
        finder = nil
        phase = result == nil ? .idle : .done
    }

    /// Shows a result with the default plan for it.
    func load(_ r: DupResult) {
        result = r
        selection = r.groups.first?.id
        let rule = KeepRule.defaultRule(twoFolders: r.twoFolders)
        if keepRule == rule { removals = rule.removals(for: r.groups) } else { keepRule = rule }
    }

    // MARK: Results

    var selectedGroup: DupGroup? {
        guard let selection else { return nil }
        return result?.groups.first { $0.id == selection }
    }

    var totalWasted: Int64 { result?.totalWasted ?? 0 }

    func group(containing file: DupFile) -> DupGroup? {
        result?.groups.first { g in g.files.contains { $0.path == file.path } }
    }

    // MARK: Removal plan

    func isMarkedForRemoval(_ file: DupFile) -> Bool { removals.contains(file.path) }

    /// Marks one copy Keep or Remove. Refuses to mark a set's last kept copy.
    func setRemove(_ file: DupFile, _ remove: Bool) {
        guard let group = group(containing: file) else { return }
        if !remove { removals.remove(file.path); return }
        let othersKept = group.files.contains { $0.path != file.path && !removals.contains($0.path) }
        guard othersKept else {
            alert = AlertInfo(title: "Every set keeps at least one copy",
                              message: "Mark another copy of “\(Format.displaySafe(file.name))” as Keep first.")
            return
        }
        removals.insert(file.path)
    }

    func removalCount(in group: DupGroup) -> Int { group.files.filter { removals.contains($0.path) }.count }

    var markedCount: Int { removals.count }

    var markedBytes: Int64 {
        result?.groups.reduce(0) { $0 + Int64(removalCount(in: $1)) * $1.size } ?? 0
    }

    // MARK: Export

    func scriptText(generated: Date = Date()) -> String {
        RemovalScript.make(groups: result?.groups ?? [], removals: removals, generated: generated,
                           folders: result?.folders ?? [])
    }

    func csvText() -> String {
        DuplicatesCSV.make(groups: result?.groups ?? [], removals: removals)
    }

    func copyScript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(scriptText(), forType: .string)
    }

    /// Saves the script with 0644 permissions: not executable, so it can't be run by double-clicking.
    func saveScript() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "remove-duplicates.sh"
        panel.allowedContentTypes = [.shellScript]
        panel.message = "Save the removal script to review and run in Terminal"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(scriptText(), to: url, what: "the script")
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "duplicates.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(csvText(), to: url, what: "the CSV file")
    }

    /// Writes text and sets 0644 (rw-r--r--) permissions.
    func write(_ text: String, to url: URL, what: String) {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        } catch {
            alert = AlertInfo(title: "Couldn't save \(what)", message: error.localizedDescription)
        }
    }

    // MARK: Actions

    func reveal(_ files: [DupFile]) {
        NSWorkspace.shared.activateFileViewerSelecting(files.map { URL(fileURLWithPath: $0.path) })
    }

    /// Explicit "Open" button: opens with the default app.
    func open(_ file: DupFile) {
        NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
    }
}
