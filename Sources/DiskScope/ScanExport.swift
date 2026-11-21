import AppKit
import UniformTypeIdentifiers

/// CSV export of scan results (one row per item), built on the shared `CSV` writer.
enum ScanCSV {
    static let header = ["path", "name", "kind", "size_on_disk_bytes", "apparent_size_bytes",
                         "items", "modified", "unreadable"]

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func kind(_ node: FileNode) -> String {
        node.isSymlink ? "symlink" : node.isDirectory ? "folder" : "file"
    }

    /// One CSV row. Names and paths go through `CSV.field` (quoting + formula neutralising).
    static func row(_ node: FileNode, path: String) -> String {
        CSV.row(encoded: [
            CSV.field(path),
            CSV.field(node.name),
            kind(node),
            CSV.number(node.diskSize),
            CSV.number(node.apparentSize),
            CSV.number(node.isDirectory ? node.itemCount : 1),
            node.modified == .distantPast ? "" : dateFormatter.string(from: node.modified),
            CSV.number(node.errorCount),
        ])
    }
}

extension AppModel {
    enum ExportScope {
        case folder   // the items in the folder being shown
        case all      // every item in the scan
    }

    /// Asks where to save, then writes the CSV and shows it in Finder.
    func exportCSV(_ scope: ExportScope) {
        guard let base = scope == .all ? root : current, !exporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let title = base.parent == nil ? PathBar.rootTitle(base) : base.name
        panel.nameFieldStringValue = "DiskScope \(scope == .all ? "scan" : "folder") – \(title.replacingOccurrences(of: "/", with: "-")).csv"
        panel.message = scope == .all ? "Export every item in the scan as CSV" : "Export the items in “\(Format.displaySafe(title))” as CSV"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await writeCSV(scope, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError {
            } catch {
                alert = AlertInfo(title: "Couldn't export CSV", message: error.localizedDescription)
            }
        }
    }

    /// Writes the CSV in chunks, yielding between them so the UI stays responsive on huge scans.
    /// Runs on the main actor because the tree is only ever touched there.
    func writeCSV(_ scope: ExportScope, to url: URL) async throws {
        guard let base = scope == .all ? root : current else { return }
        exporting = true
        defer { exporting = false }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var buffer = CSV.row(ScanCSV.header)
        func flush() throws {
            try handle.write(contentsOf: Data(buffer.utf8))
            buffer.removeAll(keepingCapacity: true)
        }
        // Paths are built while walking (cheaper than FileNode.path for every row).
        var stack: [(FileNode, String)]
        switch scope {
        case .all:
            stack = [(base, base.path)]
        case .folder:
            let prefix = base.path == "/" ? "/" : base.path + "/"
            stack = sortedChildren(of: base).reversed().map { ($0, prefix + $0.name) }
        }
        var written = 0
        while let (node, path) = stack.popLast() {
            buffer += ScanCSV.row(node, path: path)
            if scope == .all, node.isDirectory {
                let prefix = path == "/" ? "/" : path + "/"
                // Not sortedChildren(of:): caching a sorted copy of every folder would double memory.
                stack.append(contentsOf: node.children.sorted { $0.diskSize < $1.diskSize }.map { ($0, prefix + $0.name) })
            }
            written += 1
            if buffer.utf8.count > 1 << 20 { try flush() }
            if written % 20_000 == 0 {
                await Task.yield()
                try Task.checkCancellation()
            }
        }
        try flush()
    }
}
