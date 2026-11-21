import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the UI is up; folders opened before that are buffered.
    var openHandler: ((URL) -> Void)? {
        didSet { if let h = openHandler, let url = pendingOpen { pendingOpen = nil; h(url) } }
    }
    private var pendingOpen: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Folders dropped on the Dock icon or opened via "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: \.hasDirectoryPath) ?? urls.first else { return }
        if let h = openHandler { h(url) } else { pendingOpen = url }
    }
}

@main
struct DiskScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @StateObject private var volumes = VolumeStore()
    @StateObject private var dupes = DuplicatesModel()
    @StateObject private var claude = AskClaudeModel()

    var body: some Scene {
        Window("DiskScope", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(volumes)
                .environmentObject(dupes)
                .environmentObject(claude)
                .frame(minWidth: 900, minHeight: 520)
                .onAppear {
                    delegate.openHandler = { url in model.scan(url.path) }
                    // `DiskScope /some/path` or `open DiskScope.app --args /some/path`
                    if model.root == nil, let path = Self.launchPathArgument() { model.scan(path) }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Menu("Scan Disk") {
                    ForEach(volumes.volumes) { v in
                        Button(v.name) { model.scan(v) }
                    }
                }
                FindDuplicatesButton()
                Divider()
                Menu("Export as CSV") {
                    Button("Items in This Folder…") { model.exportCSV(.folder) }
                    Button("Entire Scan…") { model.exportCSV(.all) }
                }
                .disabled(model.root == nil || model.exporting)
                Divider()
                Button("Close Scan") { model.closeScan() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.root == nil && model.phase != .scanning)
            }
            CommandGroup(after: .toolbar) {
                Picker("View", selection: $model.viewMode) {
                    Text("as List").tag(ViewMode.list).keyboardShortcut("2")
                    Text("as Columns").tag(ViewMode.columns).keyboardShortcut("3")
                    Text("as Sunburst").tag(ViewMode.sunburst).keyboardShortcut("4")
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Show Apparent Size", isOn: $model.showApparentSize)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
            }
            CommandMenu("Go") {
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[")
                    .disabled(!model.canGoBack)
                Button("Forward") { model.goForward() }
                    .keyboardShortcut("]")
                    .disabled(!model.canGoForward)
                Button("Enclosing Folder") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.current?.parent == nil && model.selectedFile == nil)
                Divider()
                Button("Rescan Folder") { model.rescanCurrent() }
                    .keyboardShortcut("r")
                    .disabled(model.current == nil || model.phase == .scanning)
            }
        }

        Window("Find Duplicates", id: "duplicates") {
            DuplicatesView()
                .environmentObject(dupes)
        }
        .defaultSize(width: 1180, height: 760)

        Settings {
            TabView {
                ClaudeSettingsView()
                    .tabItem { Label("Ask Claude", systemImage: "sparkles") }
            }
            .environmentObject(claude)
            .frame(width: 520)
        }
    }
}

/// "Find Duplicates…" (⇧⌘D): opens the duplicates window.
struct FindDuplicatesButton: View {
    @Environment(\.openWindow) private var openWindow
    var title = "Find Duplicates…"
    var body: some View {
        Button(title) { openWindow(id: "duplicates") }
            .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}

extension DiskScopeApp {
    /// First non-flag argument that names an existing directory.
    private static func launchPathArgument() -> String? {
        var args = Array(CommandLine.arguments.dropFirst())
        while let a = args.first {
            args.removeFirst()
            if a.hasPrefix("-") {
                // Skip AppKit-style "-Key value" pairs (e.g. -NSDocumentRevisionsDebugMode YES).
                if let next = args.first, !next.hasPrefix("-"), !next.hasPrefix("/"), !next.hasPrefix("~") { args.removeFirst() }
                continue
            }
            let path = (a as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return path }
        }
        return nil
    }
}
