import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            DetailView()
        }
        .alert(item: $model.alert) { info in
            Alert(title: Text(info.title), message: Text(info.message))
        }
        .confirmationDialog(trashTitle,
                            isPresented: Binding(get: { !model.pendingTrash.isEmpty },
                                                 set: { if !$0 { model.pendingTrash = [] } })) {
            Button("Move to Trash", role: .destructive) { model.confirmTrash() }
            Button("Cancel", role: .cancel) { model.pendingTrash = [] }
        } message: {
            Text(verbatim: trashMessage)
        }
    }

    private var trashTitle: String {
        let items = model.pendingTrash
        if items.isEmpty { return "" }
        return items.count == 1 ? "Move “\(Format.displaySafe(items[0].name))” to the Trash?"
                                : "Move \(items.count) items to the Trash?"
    }

    /// Full paths (sanitized) so it's unambiguous what will be moved.
    private var trashMessage: String {
        let items = model.pendingTrash
        let shown = items.prefix(6).map { Format.displaySafe($0.path) }
        let more = items.count > shown.count ? "\n…and \(items.count - shown.count) more" : ""
        let size = Format.bytes(items.reduce(0) { $0 + $1.diskSize })
        return shown.joined(separator: "\n") + more + "\n\nThis frees about \(size) once the Trash is emptied."
    }
}

private struct DetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.phase {
        case .idle:
            WelcomeView().navigationTitle("DiskScope")
        case .scanning:
            ScanningView().navigationTitle("Scanning…")
        case .browsing:
            if let current = model.current {
                BrowserView(current: current)
            } else {
                WelcomeView().navigationTitle("DiskScope")
            }
        }
    }
}

// MARK: - Browser

struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    let current: FileNode

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if !model.searchText.isEmpty {
                    SearchResultsView()
                } else {
                    switch model.viewMode {
                    case .columns: ColumnBrowser(current: current)
                    case .list: ListBrowser(current: current)
                    case .sunburst: SunburstView(current: current)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PathBar(current: current)
            Divider()
            StatusBar(current: current)
        }
        .navigationTitle(current.parent == nil ? PathBar.rootTitle(current) : current.name)
        .navigationSubtitle(Format.bytes(model.size(of: current)))
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .task(id: SearchKey(text: model.searchText, whole: model.searchWholeScan, revision: model.revision)) {
            try? await Task.sleep(for: .milliseconds(250)) // debounce typing
            guard !Task.isCancelled else { return }
            await model.performSearch()
        }
        .toolbar { BrowserToolbar(current: current) }
    }

    private struct SearchKey: Equatable { let text: String; let whole: Bool; let revision: Int }
}

private struct BrowserToolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel
    let current: FileNode

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { model.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!model.canGoBack)
                    .help("See folders you viewed previously (⌘[)")
                Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(!model.canGoForward)
                    .help("See folders you viewed next (⌘])")
            }
            .controlGroupStyle(.navigation)
        }

        ToolbarItem {
            Picker("View", selection: $model.viewMode) {
                Label("as List", systemImage: "list.bullet").tag(ViewMode.list)
                Label("as Columns", systemImage: "rectangle.split.3x1").tag(ViewMode.columns)
            }
            .pickerStyle(.segmented)
            .help("Change the item arrangement")
        }

        ToolbarItem {
            Menu {
                Picker("Sort By", selection: Binding(get: { model.sortKey }, set: { if let k = $0 { model.setSort(k) } })) {
                    ForEach(SortKey.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Size Shown", selection: $model.showApparentSize) {
                    Text("Space on Disk").tag(false)
                    Text("File Size (Apparent)").tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Change sort order and which size is shown")
        }

        ToolbarItemGroup {
            let targets = model.actionTargets
            Button { model.revealInFinder(targets.isEmpty ? [current] : targets) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Show the selection in Finder")

            Button { model.requestTrash(targets) } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .disabled(targets.isEmpty)
            .keyboardShortcut(.delete, modifiers: .command)
            .help("Move the selection to the Trash (⌘⌫)")

            Menu {
                Button("Rescan “\(current.parent == nil ? PathBar.rootTitle(current) : current.name)”") { model.rescanCurrent() }
                Button("Copy Path") { model.copyPaths(targets.isEmpty ? [current] : targets) }
                Divider()
                Button("Scan Another Folder…") { model.chooseFolder() }
                Button("Close Scan") { model.closeScan() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More actions")
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var volumes: VolumeStore
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon).resizable().frame(width: 96, height: 96)
                    }
                    Text("DiskScope").font(.largeTitle.bold())
                    Text("Pick a drive or folder to see what's using the space.")
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    ForEach(volumes.volumes) { v in
                        VolumeCard(volume: v) { model.scan(v) }
                    }
                }

                HStack {
                    Button("Choose Folder…") { model.chooseFolder() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Text("or drop a folder here").foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.scan(url.path)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

struct VolumeCard: View {
    let volume: Volume
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: volume.symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(volume.name).font(.headline).lineLimit(1)
                        Text(volume.kind).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(volume.usedFraction.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    CapacityBar(fraction: volume.usedFraction)
                    Text("\(Format.bytes(volume.available)) free of \(Format.bytes(volume.total))"
                         + (volume.format.isEmpty ? "" : " · \(volume.format)"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(hovering ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Scan \(volume.path)")
    }
}

// MARK: - Scanning

struct ScanningView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Scanning “\(model.scanTarget == "/" ? "/" : (model.scanTarget as NSString).lastPathComponent)”…")
                .font(.title2.bold())
            Text("\(Format.count(model.stats.items)) items · \(Format.bytes(model.stats.bytes))")
                .monospacedDigit()
            if model.stats.errors > 0 {
                Text("\(Format.count(model.stats.errors)) unreadable")
                    .foregroundStyle(.orange)
            }
            Text(model.stats.currentPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 560)
            Button("Cancel") { model.cancelScan() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
