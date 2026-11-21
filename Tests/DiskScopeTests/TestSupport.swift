import Foundation
import Darwin
@testable import DiskScope

/// A throwaway directory tree under the system temp dir, removed on `cleanup()`.
/// Paths are canonical (realpath), matching what AppModel/Scanner produce.
final class TempTree {
    let root: String

    init(_ label: String = "t") {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskScopeTests-\(label)-\(UUID().uuidString)").path
        try! FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = TrashGuard.realPath(base)!
    }

    func path(_ rel: String) -> String { rel.isEmpty ? root : root + "/" + rel }

    @discardableResult
    func dir(_ rel: String) -> String {
        let p = path(rel)
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// Creates a file of exactly `bytes` bytes (parent dirs created as needed).
    @discardableResult
    func file(_ rel: String, bytes: Int = 0, mode: mode_t = 0o644) -> String {
        let p = path(rel)
        dir((rel as NSString).deletingLastPathComponent)
        FileManager.default.createFile(atPath: p, contents: Data(repeating: 0x41, count: bytes))
        chmod(p, mode)
        return p
    }

    @discardableResult
    func symlink(_ rel: String, to target: String) -> String {
        let p = path(rel)
        try! FileManager.default.createSymbolicLink(atPath: p, withDestinationPath: target)
        return p
    }

    @discardableResult
    func hardlink(_ rel: String, to existingRel: String) -> String {
        let p = path(rel)
        dir((rel as NSString).deletingLastPathComponent)
        try! FileManager.default.linkItem(atPath: path(existingRel), toPath: p)
        return p
    }

    /// Restores permissions everywhere and deletes the tree (handles paths longer than PATH_MAX via rm).
    func cleanup() {
        run("/bin/chmod", ["-R", "u+rwx", root])
        run("/bin/rm", ["-rf", root])
    }

    deinit { cleanup() }
}

@discardableResult
func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

/// lstat-based expectations used to check the scanner against the real filesystem.
func diskBytes(_ path: String) -> Int64 {
    var st = stat()
    precondition(lstat(path, &st) == 0, "lstat \(path)")
    return Int64(st.st_blocks) * 512
}

func apparentBytes(_ path: String) -> Int64 {
    var st = stat()
    precondition(lstat(path, &st) == 0, "lstat \(path)")
    return Int64(st.st_size)
}

func mtimeSeconds(_ path: String) -> Int {
    var st = stat()
    precondition(lstat(path, &st) == 0, "lstat \(path)")
    return Int(st.st_mtimespec.tv_sec)
}

/// Synchronous scan helper.
func scanTree(_ path: String, stayOnDevice: Bool = false, threads: Int = 4) throws -> FileNode {
    try Scanner().scan(path: path, stayOnDevice: stayOnDevice, threads: threads) { _ in }!
}

extension FileNode {
    /// Child by name (test convenience).
    subscript(_ name: String) -> FileNode? { children.first { $0.name == name } }

    /// Descend by a "/"-separated relative path.
    func at(_ rel: String) -> FileNode? {
        var n: FileNode? = self
        for part in rel.split(separator: "/") { n = n?[String(part)] }
        return n
    }

    /// Every node in the subtree (pre-order).
    var allNodes: [FileNode] {
        var out: [FileNode] = []
        var stack = [self]
        while let n = stack.popLast() { out.append(n); stack.append(contentsOf: n.children) }
        return out
    }
}

/// Builds an in-memory tree with explicit sizes; directory totals via aggregateTotals.
/// Spec: "a/b/file:100" → file of 100 bytes (disk = apparent = 100); "dir/" → empty dir.
func makeTree(rootName: String, _ specs: [String]) -> FileNode {
    let root = FileNode(name: rootName, isDirectory: true, isSymlink: false,
                        diskSize: 0, apparentSize: 0, mtime: 0, parent: nil)
    for spec in specs {
        let parts = spec.split(separator: ":", maxSplits: 1)
        let rel = String(parts[0])
        let size = parts.count > 1 ? Int64(parts[1])! : 0
        let isDirSpec = rel.hasSuffix("/")
        let comps = rel.split(separator: "/").map(String.init)
        var cur = root
        for (i, c) in comps.enumerated() {
            let last = i == comps.count - 1
            if let existing = cur[c] { cur = existing; continue }
            let isDir = !last || isDirSpec
            let node = FileNode(name: c, isDirectory: isDir, isSymlink: false,
                                diskSize: isDir ? 0 : size, apparentSize: isDir ? 0 : size,
                                mtime: 1_700_000_000 + i, parent: cur)
            cur.children.append(node)
            cur = node
        }
    }
    FileNode.aggregateTotals(from: root)
    return root
}

/// Polls the main actor until the model leaves `.scanning` (scans finish asynchronously).
@MainActor
func waitForScan(_ model: AppModel, timeout: TimeInterval = 20) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    // Let a just-started scan get going, then wait for completion.
    try await Task.sleep(for: .milliseconds(5))
    while model.phase == .scanning {
        if Date() > deadline { throw TestTimeout() }
        try await Task.sleep(for: .milliseconds(10))
    }
    // Allow the trailing completion hop (revision bump etc.) to land.
    try await Task.sleep(for: .milliseconds(10))
}

@MainActor
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw TestTimeout() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

struct TestTimeout: Error {}

/// Records what would have been trashed; optionally deletes it (inside temp dirs only) or throws.
final class FakeTrash: @unchecked Sendable {
    var trashed: [String] = []
    var deleteForReal = true
    var error: Error?

    var trasher: (URL) throws -> Void {
        { [self] url in
            if let error { throw error }
            precondition(url.path.contains("DiskScopeTests-"), "refusing to delete outside test temp dirs: \(url.path)")
            trashed.append(url.path)
            if deleteForReal { try FileManager.default.removeItem(at: url) }
        }
    }
}
