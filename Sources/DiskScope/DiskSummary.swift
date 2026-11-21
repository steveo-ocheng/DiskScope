import Foundation

/// The text Ask Claude sends about a scan: names, sizes and dates only — never file contents.
/// Kept compact (well under ~6k tokens) and bounded in work, since trees can hold millions of nodes.
enum DiskSummary {
    static let largestFolders = 40
    static let largestFiles = 40
    static let currentChildren = 25
    static let maxPathLength = 160
    static let maxCharacters = 30_000

    static func make(root: FileNode, current: FileNode, hidden: HiddenSpace?, volume: VolumeSummary?,
                     showApparent: Bool, home: String = NSHomeDirectory()) -> String {
        let size: (FileNode) -> Int64 = showApparent ? { $0.apparentSize } : { $0.diskSize }
        let rootPath = root.path
        var out: [String] = []

        out.append("# DiskScope scan summary")
        let isDisk = hidden != nil
        out.append("Scanned: \(displayPath(rootPath, home: home))" + (isDisk ? " (whole disk)" : " (folder)"))
        out.append("Sizes are " + (showApparent ? "apparent file sizes (bytes in the files)." : "space used on disk."))
        out.append("Total: \(sizeText(size(root))) in \(Format.count(root.itemCount)) items")
        if root.errorCount > 0 {
            out.append("Unreadable: \(Format.count(root.errorCount)) items couldn't be read (macOS denied access or they changed during the scan); their space isn't counted.")
        }
        if let volume {
            out.append("Volume “\(Format.displaySafe(volume.name))”: \(Format.bytes(volume.total)) capacity, \(Format.bytes(volume.available)) available.")
        }

        if let hidden {
            out.append("")
            out.append("## Used space not found in files")
            out.append("Disk reports \(sizeText(hidden.used)) used; scanned files account for \(sizeText(hidden.scanned)).")
            for part in hidden.otherVolumes {
                out.append("- Other volume on this disk: \(Format.displaySafe(part.name)) (\(part.mountPoint)) \(sizeText(part.bytes))")
            }
            var notes: [String] = []
            if hidden.snapshots > 0 { notes.append("\(hidden.snapshots) Time Machine local snapshots") }
            if hidden.unreadable > 0 { notes.append("\(Format.count(hidden.unreadable)) unreadable items") }
            notes.append("filesystem metadata and hidden system data")
            out.append("- Not visible to the scan: \(sizeText(hidden.invisible)) (" + notes.joined(separator: ", ") + ")")
            if hidden.purgeable > 0 {
                out.append("- Purgeable (macOS frees it automatically when space runs low): \(sizeText(hidden.purgeable))")
            }
            if hidden.scannedExceedsUsed {
                out.append("- The files add up to more than the used space: APFS clones and copies share storage.")
            }
        }

        let (folders, files) = largest(in: root, size: size)
        out.append("")
        out.append("## Largest folders in the scan (path relative to the scanned folder)")
        if folders.isEmpty { out.append("(none)") }
        for f in folders {
            out.append("- \(sizeText(size(f))) · \(relativePath(f, root: root)) · \(Format.count(f.itemCount)) items\(dateText(f))")
        }
        out.append("")
        out.append("## Largest files in the scan")
        if files.isEmpty { out.append("(none)") }
        for f in files {
            out.append("- \(sizeText(size(f))) · \(relativePath(f, root: root))\(dateText(f))")
        }

        if current !== root {
            out.append("")
            out.append("## Folder the user is looking at: \(relativePath(current, root: root)) — \(sizeText(size(current))), \(Format.count(current.itemCount)) items")
        } else {
            out.append("")
            out.append("## Top items in the scanned folder")
        }
        let children = top(current.children, count: currentChildren, size: size)
        for c in children {
            let kind = c.isSymlink ? "link" : (c.isDirectory ? "folder" : "file")
            out.append("- \(sizeText(size(c))) · \(clip(Format.displaySafe(c.name))) (\(kind))\(dateText(c))")
        }
        if current.children.count > children.count {
            out.append("- …and \(Format.count(current.children.count - children.count)) smaller items")
        }

        var text = out.joined(separator: "\n")
        if text.count > maxCharacters { text = String(text.prefix(maxCharacters)) + "\n(summary truncated)" }
        return text
    }

    /// Extra section for duplicate-file findings (fed by Find Duplicates).
    static func duplicatesSection(lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        let shown = lines.prefix(30).map { "- " + clip(Format.displaySafe($0), max: 240) }
        var text = "## Duplicate files found\n" + shown.joined(separator: "\n")
        if lines.count > shown.count { text += "\n- …and \(lines.count - shown.count) more sets" }
        return text
    }

    // MARK: Selection

    /// One iterative pass over the whole tree, keeping only the biggest few of each kind.
    /// Folders that are almost entirely one already-listed subfolder are dropped as redundant
    /// (e.g. "Library" when "Library/Containers" holds 98% of it).
    static func largest(in root: FileNode, size: (FileNode) -> Int64) -> (folders: [FileNode], files: [FileNode]) {
        var folders = TopList(capacity: largestFolders * 3)
        var files = TopList(capacity: largestFiles)
        var stack: [FileNode] = root.children
        while let node = stack.popLast() {
            let s = size(node)
            if node.isDirectory {
                folders.offer(node, s)
                if !node.children.isEmpty { stack.append(contentsOf: node.children) }
            } else if !node.isSymlink {
                files.offer(node, s)
            }
        }
        let candidates = folders.nodes
        let ids = Set(candidates.map(ObjectIdentifier.init))
        let redundant = Set(candidates.compactMap { node -> ObjectIdentifier? in
            guard let parent = node.parent, parent !== root, ids.contains(ObjectIdentifier(parent)) else { return nil }
            return size(node) * 100 >= size(parent) * 95 ? ObjectIdentifier(parent) : nil
        })
        let kept = candidates.filter { !redundant.contains(ObjectIdentifier($0)) }
        return (Array(kept.prefix(largestFolders)), files.nodes)
    }

    private static func top(_ nodes: [FileNode], count: Int, size: (FileNode) -> Int64) -> [FileNode] {
        var list = TopList(capacity: count)
        for n in nodes { list.offer(n, size(n)) }
        return list.nodes
    }

    /// Keeps the `capacity` largest entries, sorted largest first (insertion only beats the smallest).
    struct TopList {
        let capacity: Int
        private var entries: [(size: Int64, node: FileNode)] = []
        init(capacity: Int) { self.capacity = capacity; entries.reserveCapacity(capacity + 1) }

        mutating func offer(_ node: FileNode, _ size: Int64) {
            guard size > 0, capacity > 0 else { return }
            if entries.count == capacity, let last = entries.last, size <= last.size { return }
            var lo = 0, hi = entries.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if entries[mid].size >= size { lo = mid + 1 } else { hi = mid }
            }
            entries.insert((size, node), at: lo)
            if entries.count > capacity { entries.removeLast() }
        }

        var nodes: [FileNode] { entries.map(\.node) }
    }

    // MARK: Formatting

    static func displayPath(_ path: String, home: String) -> String {
        let safe = Format.displaySafe(path)
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + Format.displaySafe(String(path.dropFirst(home.count))) }
        return safe
    }

    /// Path below the scan root, every component made display-safe.
    static func relativePath(_ node: FileNode, root: FileNode) -> String {
        var names: [String] = []
        var n: FileNode? = node
        while let c = n, c !== root { names.append(Format.displaySafe(c.name)); n = c.parent }
        return clip(names.reversed().joined(separator: "/"))
    }

    static func clip(_ s: String, max: Int = maxPathLength) -> String {
        guard s.count > max else { return s }
        let half = (max - 1) / 2
        return String(s.prefix(half)) + "…" + String(s.suffix(half))
    }

    private static func sizeText(_ bytes: Int64) -> String {
        "\(Format.bytes(bytes)) (\(bytes) bytes)"
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    private static func dateText(_ node: FileNode) -> String {
        node.modified == .distantPast ? "" : " · modified \(dateFormatter.string(from: node.modified))"
    }
}
