import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// The Find Duplicates window: pick one or two folders, find files with identical contents,
/// and compare copies side by side.
struct DuplicatesView: View {
    @EnvironmentObject var dupes: DuplicatesModel

    var body: some View {
        VStack(spacing: 0) {
            DupSetupBar()
            Divider()
            Group {
                switch dupes.phase {
                case .idle:
                    DupIntro()
                case .running:
                    DupRunningView()
                case .done:
                    if let r = dupes.result, !r.groups.isEmpty {
                        DupResultsView(result: r)
                    } else {
                        DupNoResults()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 560)
        .navigationTitle("Find Duplicates")
        .alert(item: $dupes.alert) { info in
            Alert(title: Text(info.title), message: Text(info.message))
        }
        .sheet(isPresented: $dupes.showingScript) {
            RemovalScriptSheet()
        }
    }
}

// MARK: - Setup

private struct DupSetupBar: View {
    @EnvironmentObject var dupes: DuplicatesModel

    private static let sizes: [(String, Int64)] = [
        ("Any size", 1), ("1 KB", 1024), ("100 KB", 100 * 1024),
        ("1 MB", 1024 * 1024), ("10 MB", 10 * 1024 * 1024),
    ]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                FolderSlot(side: .a, title: "Folder A")
                Button { dupes.swapFolders() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("Swap the two folders")
                .disabled(dupes.phase == .running)
                FolderSlot(side: .b, title: "Folder B (optional)")
            }
            HStack(spacing: 16) {
                Picker("Ignore files smaller than", selection: $dupes.options.minSize) {
                    ForEach(Self.sizes, id: \.1) { Text($0.0).tag($0.1) }
                }
                .fixedSize()
                Toggle("Hidden files", isOn: $dupes.options.includeHidden)
                    .help("Include files whose names start with a dot")
                Toggle("Inside packages", isOn: $dupes.options.includePackages)
                    .help("Look inside apps, libraries and other bundles that Finder shows as a single file")
                if dupes.folderA != nil && dupes.folderB != nil {
                    Toggle("Also within one folder", isOn: $dupes.options.includeSameFolder)
                        .help("Also show copies that are all inside Folder A, or all inside Folder B")
                }
                Spacer()
                if dupes.phase == .running {
                    Button("Cancel") { dupes.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Find Duplicates") { dupes.start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!dupes.canStart)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(dupes.phase == .running)
        }
        .padding(12)
    }
}

private struct FolderSlot: View {
    @EnvironmentObject var dupes: DuplicatesModel
    let side: DupSide
    let title: String
    @State private var targeted = false

    var body: some View {
        let path = dupes.folder(side)
        HStack(spacing: 10) {
            Image(nsImage: path.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(path == nil ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    SideChip(side: side)
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
                if let path {
                    Text(Format.displaySafe(path == "/" ? "/" : (path as NSString).lastPathComponent))
                        .font(.headline).lineLimit(1)
                    Text(Format.displaySafe((path as NSString).deletingLastPathComponent))
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(side == .a ? "Choose or drop a folder" : "Leave empty to search within Folder A")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if path != nil {
                Button { dupes.set(side, path: nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear")
            }
            Button("Choose…") { dupes.choose(side) }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(targeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: path == nil ? [4, 3] : []))
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35)))
        .help(path.map(Format.displaySafe) ?? "")
        .disabled(dupes.phase == .running)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.hasDirectoryPath || isDirectory(url) else { return false }
            dupes.set(side, path: url.path)
            return true
        } isTargeted: { targeted = $0 }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

struct SideChip: View {
    let side: DupSide
    var count: Int?

    var body: some View {
        Text(count.map { "\(side.label) ×\($0)" } ?? side.label)
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(.white)
            .background(Capsule().fill(side == .a ? Color.accentColor : Color.orange))
    }
}

// MARK: - States

private struct DupIntro: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Find files with identical contents").font(.title2.bold())
            Text("Choose two folders to find files that exist in both, or just one folder to find copies inside it. "
                 + "Files are compared by size and then by a SHA-256 checksum of their contents, so names don't matter.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Text("Files stored only in iCloud or other cloud drives are skipped, so nothing is downloaded.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }
}

private struct DupRunningView: View {
    @EnvironmentObject var dupes: DuplicatesModel

    var body: some View {
        let p = dupes.progress
        VStack(spacing: 12) {
            if let fraction = p.fraction {
                ProgressView(value: fraction).frame(width: 360)
            } else {
                ProgressView().controlSize(.large)
            }
            switch p.stage {
            case .listing:
                Text("Listing files…").font(.title3.bold())
                Text("\(Format.count(p.filesSeen)) files found").monospacedDigit()
            case .hashing:
                Text("Comparing contents…").font(.title3.bold())
                Text("\(Format.count(p.hashedFiles)) of \(Format.count(p.candidates)) files with matching sizes · "
                     + "\(Format.bytes(p.bytesHashed)) of \(Format.bytes(p.bytesToHash)) read")
                    .monospacedDigit()
            }
            Text(Format.displaySafe(p.currentPath))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 560)
            Button("Cancel") { dupes.cancel() }
        }
        .padding(40)
    }
}

private struct DupNoResults: View {
    @EnvironmentObject var dupes: DuplicatesModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("No duplicates found").font(.title2.bold())
            if let r = dupes.result {
                Text("Compared \(Format.count(r.filesSeen)) files"
                     + (r.twoFolders && !dupes.options.includeSameFolder ? " — no file in Folder A has a copy in Folder B." : "."))
                    .foregroundStyle(.secondary)
                DupSkippedNote(result: r)
            }
        }
        .padding(40)
    }
}

private struct DupSkippedNote: View {
    let result: DupResult

    var body: some View {
        let parts = [
            result.skippedCloud > 0 ? "\(Format.count(result.skippedCloud)) in the cloud skipped" : nil,
            result.skippedUnreadable > 0 ? "\(Format.count(result.skippedUnreadable)) unreadable" : nil,
            result.hardLinks > 0 ? "\(Format.count(result.hardLinks)) hard links (already share storage)" : nil,
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Results

private struct DupResultsView: View {
    @EnvironmentObject var dupes: DuplicatesModel
    let result: DupResult

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(Format.count(result.groups.count)) duplicate \(result.groups.count == 1 ? "set" : "sets") · "
                         + "\(Format.bytes(result.totalWasted)) could be freed")
                        .font(.headline)
                    Text("Compared \(Format.count(result.filesSeen)) files").font(.caption).foregroundStyle(.secondary)
                    DupSkippedNote(result: result)
                    Picker("Keep", selection: $dupes.keepRule) {
                        ForEach(KeepRule.available(twoFolders: result.twoFolders)) { Text($0.rawValue).tag($0) }
                    }
                    .help("Which copy of each set to keep. You can still change any copy by hand.")
                    Text("\(Format.count(dupes.markedCount)) \(dupes.markedCount == 1 ? "file" : "files") marked for removal · "
                         + "\(Format.bytes(dupes.markedBytes)) would be freed")
                        .font(.callout)
                    HStack {
                        Button("Removal Script…") { dupes.showingScript = true }
                            .help("Make a script you review and run yourself. DiskScope never deletes files.")
                            .disabled(dupes.markedCount == 0)
                        Button("Export CSV…") { dupes.exportCSV() }
                            .help("Save every duplicate set and its plan as a spreadsheet")
                    }
                    .controlSize(.small)
                }
                .padding(10)
                Divider()
                List(selection: $dupes.selection) {
                    ForEach(result.groups) { g in
                        DupGroupRow(group: g, twoFolders: result.twoFolders).tag(g.id)
                    }
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 260, idealWidth: 330, maxWidth: 460)

            Group {
                if let g = dupes.selectedGroup {
                    DupCompareView(group: g, twoFolders: result.twoFolders).id(g.id)
                } else {
                    Text("Select a duplicate set to compare its copies")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DupGroupRow: View {
    @EnvironmentObject var dupes: DuplicatesModel
    let group: DupGroup
    let twoFolders: Bool

    var body: some View {
        let first = group.files[0]
        HStack(spacing: 8) {
            Image(nsImage: DupIcons.icon(forName: first.name))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.displaySafe(first.name)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text("\(group.copies) copies · \(Format.bytes(group.size)) each")
                        .font(.caption).foregroundStyle(.secondary)
                    if twoFolders {
                        let a = group.files(on: .a).count, b = group.files(on: .b).count
                        if a > 0 { SideChip(side: .a, count: a) }
                        if b > 0 { SideChip(side: .b, count: b) }
                    }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(group.wasted))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Space freed by keeping one copy")
                let marked = dupes.removalCount(in: group)
                Text(marked == 0 ? "keep all" : "\(marked) to remove")
                    .font(.caption2)
                    .foregroundStyle(marked == 0 ? Color.secondary : Color.red)
            }
        }
        .padding(.vertical, 2)
    }
}

@MainActor
enum DupIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(forName name: String) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        if let img = cache[ext] { return img }
        if cache.count > 500 { cache.removeAll() }
        let img = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache[ext] = img
        return img
    }
}

// MARK: - Compare

private struct DupCompareView: View {
    @EnvironmentObject var dupes: DuplicatesModel
    let group: DupGroup
    let twoFolders: Bool

    @State private var leftPath: String?
    @State private var rightPath: String?
    @StateObject private var players = PreviewPlayers()

    private var left: DupFile? { group.files.first { $0.path == leftPath } ?? defaults.0 }
    private var right: DupFile? { group.files.first { $0.path == rightPath } ?? defaults.1 }

    /// Left: first copy in A; right: first copy in B (or simply the second copy).
    private var defaults: (DupFile?, DupFile?) {
        let a = group.files(on: .a), b = group.files(on: .b)
        if twoFolders, let l = a.first, let r = b.first { return (l, r) }
        return (group.files.first, group.files.dropFirst().first)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if let left {
                    DupPane(file: left, choices: group.files,
                            selection: Binding(get: { left.path }, set: { leftPath = $0 }),
                            player: players.player(for: left.path))
                }
                Divider()
                if let right {
                    DupPane(file: right, choices: group.files,
                            selection: Binding(get: { right.path }, set: { rightPath = $0 }),
                            player: players.player(for: right.path))
                }
            }
            if group.files.count > 2 {
                Divider()
                AllCopiesList(group: group, twoFolders: twoFolders)
            }
        }
        .onChange(of: [left?.path, right?.path]) { _, paths in players.keep(paths.compactMap { $0 }) }
        .onDisappear { players.pauseAll() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            Text("Identical contents").font(.headline)
            Text("SHA-256 \(group.digest.prefix(16))…")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .help("SHA-256: \(group.digest)")
            Spacer()
            if let l = left, let r = right, PreviewLoader.isMedia(l.path), PreviewLoader.isMedia(r.path) {
                Button { players.playTogether([l.path, r.path]) } label: {
                    Label("Play Both", systemImage: "play.fill")
                }
                .help("Play both copies from the start, side by side")
            }
            Text("\(group.copies) copies · \(Format.bytes(group.size)) each")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct DupPane: View {
    @EnvironmentObject var dupes: DuplicatesModel
    let file: DupFile
    let choices: [DupFile]
    @Binding var selection: String
    let player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    SideChip(side: file.side)
                    if choices.count > 2 {
                        Picker("Copy", selection: $selection) {
                            ForEach(choices) { f in
                                Text("\(f.side.label): \(Format.displaySafe(f.name)) — \(Format.displaySafe((f.folder as NSString).lastPathComponent))")
                                    .tag(f.path)
                            }
                        }
                        .labelsHidden()
                    } else {
                        Text(Format.displaySafe(file.name)).font(.headline).lineLimit(1).truncationMode(.middle)
                    }
                }
                Text(Format.displaySafe(file.folder))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(Format.displaySafe(file.path))
                Text("Modified \(file.modified.formatted(date: .abbreviated, time: .shortened)) · \(Format.bytes(file.size))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            Divider()
            ContentPreview(path: file.path, player: player)
            Divider()
            HStack {
                Button("Show in Finder") { dupes.reveal([file]) }
                Button("Open") { dupes.open(file) }
                Spacer()
                PlanPicker(file: file)
            }
            .controlSize(.small)
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AllCopiesList: View {
    @EnvironmentObject var dupes: DuplicatesModel
    let group: DupGroup
    let twoFolders: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("All \(group.copies) copies").font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(group.files) { f in
                        HStack(spacing: 6) {
                            if twoFolders { SideChip(side: f.side) }
                            Text(Format.displaySafe(f.path))
                                .font(.caption)
                                .lineLimit(1).truncationMode(.middle)
                                .help(Format.displaySafe(f.path))
                            Spacer(minLength: 4)
                            Button { dupes.reveal([f]) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless)
                                .help("Show in Finder")
                            PlanPicker(file: f).controlSize(.mini)
                        }
                    }
                }
            }
            .frame(maxHeight: 110)
        }
        .padding(10)
    }
}

/// Keep / Remove for one copy. The model refuses to remove a set's last kept copy.
private struct PlanPicker: View {
    @EnvironmentObject var dupes: DuplicatesModel
    let file: DupFile

    var body: some View {
        Picker("Plan", selection: Binding(get: { dupes.isMarkedForRemoval(file) },
                                          set: { dupes.setRemove(file, $0) })) {
            Text("Keep").tag(false)
            Text("Remove").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Whether the removal script moves this copy to the Trash")
    }
}

/// Shows the generated removal script with Copy / Save. DiskScope itself never deletes anything.
private struct RemovalScriptSheet: View {
    @EnvironmentObject var dupes: DuplicatesModel
    @Environment(\.dismiss) private var dismiss
    @State private var script = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Removal Script").font(.title2.bold())
            Text("DiskScope never deletes files itself. Review this script, then run it in Terminal: "
                 + "first `bash remove-duplicates.sh` (dry run: shows what it would do), then "
                 + "`bash remove-duplicates.sh --apply` to move the files to the Trash.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Before moving anything, the script re-checks each file's size and SHA-256 checksum, and that the "
                 + "copy being kept is still there. \(Format.count(dupes.markedCount)) "
                 + "\(dupes.markedCount == 1 ? "file" : "files") marked for removal (\(Format.bytes(dupes.markedBytes))).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ReadOnlyTextView(text: script)
                .frame(minHeight: 320)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Button("Copy") { dupes.copyScript() }
                Button("Save…") { dupes.saveScript() }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 640)
        .onAppear { script = dupes.scriptText() }
    }
}
