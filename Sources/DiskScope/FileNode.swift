import Foundation

/// One entry in the scanned tree. Directory sizes are the totals of everything beneath them.
///
/// Memory matters: a full-disk scan can hold several million of these, so stored
/// properties are kept compact (32-bit counters / timestamp, Bools packed last) and the
/// parent link is `unowned` rather than `weak` (weak references force a side-table
/// allocation per referenced object and are slower to load).
///
/// Ownership: a node strongly owns its `children`; `parent` never keeps anything alive.
/// Anything that detaches a node from its parent must set `parent = nil` (see `remove`,
/// `replace`). Don't keep a node alive after its tree is released: reading its `parent`
/// would trap (by design: a crash is safer than a truncated path reaching Trash).
final class FileNode: Identifiable, @unchecked Sendable {
    var name: String           // root's name is its full path; settable so a rescanned subtree can be renamed
    var diskSize: Int64        // bytes allocated on disk (st_blocks * 512); totals for directories
    var apparentSize: Int64    // logical size (st_size); totals for directories
    var children: [FileNode] = []
    unowned var parent: FileNode?
    private var mtimeSeconds: UInt32   // seconds since 1970; 0 = unknown
    private var storedItemCount: UInt32 = 0
    private var storedErrorCount: UInt32 = 0
    let isDirectory: Bool
    let isSymlink: Bool

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    /// Number of descendants (0 for files).
    var itemCount: Int {
        get { Int(storedItemCount) }
        set { storedItemCount = UInt32(clamping: newValue) }
    }

    /// Unreadable entries at or below this node.
    var errorCount: Int {
        get { Int(storedErrorCount) }
        set { storedErrorCount = UInt32(clamping: newValue) }
    }

    var modified: Date {
        mtimeSeconds == 0 ? .distantPast : Date(timeIntervalSince1970: TimeInterval(mtimeSeconds))
    }

    init(name: String, isDirectory: Bool, isSymlink: Bool, diskSize: Int64,
         apparentSize: Int64, modified: Date, parent: FileNode?) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.diskSize = diskSize
        self.apparentSize = apparentSize
        self.mtimeSeconds = modified == .distantPast ? 0 : UInt32(clamping: Int64(modified.timeIntervalSince1970))
        self.parent = parent
    }

    /// Fast path used by the scanner (avoids Date round-trips).
    init(name: String, isDirectory: Bool, isSymlink: Bool, diskSize: Int64,
         apparentSize: Int64, mtime: Int, parent: FileNode?) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.diskSize = diskSize
        self.apparentSize = apparentSize
        self.mtimeSeconds = UInt32(clamping: mtime)
        self.parent = parent
    }

    /// Tear down iteratively: default deinit would recurse once per tree level,
    /// which can overflow the stack on pathologically deep trees.
    deinit {
        guard !children.isEmpty else { return }
        var stack = children
        children = []
        while var node = stack.popLast() {
            // Only dismantle nodes nobody else holds. A node still referenced elsewhere
            // (e.g. children adopted by another parent) is left untouched; note that
            // reading `parent` here is never safe because it may be `self`, mid-deinit.
            if isKnownUniquelyReferenced(&node) {
                stack.append(contentsOf: node.children)
                node.children = []
            }
        }
    }

    /// Full path. The root node's name is its full path.
    var path: String {
        var names: [String] = []
        var n: FileNode? = self
        while let c = n { names.append(c.name); n = c.parent }
        var result = names.removeLast()
        for name in names.reversed() {
            if !result.hasSuffix("/") { result += "/" }
            result += name
        }
        return result
    }

    /// Chain from the root down to this node.
    var ancestry: [FileNode] {
        var chain: [FileNode] = []
        var n: FileNode? = self
        while let c = n { chain.append(c); n = c.parent }
        return chain.reversed()
    }

    /// Detach a child and subtract its totals from every ancestor.
    func remove(_ child: FileNode) {
        guard let i = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: i)
        child.parent = nil
        propagate(disk: -child.diskSize, apparent: -child.apparentSize,
                  items: -(child.itemCount + 1), errors: -child.errorCount)
    }

    /// Swap a child for a freshly scanned version and fix ancestor totals.
    func replace(_ old: FileNode, with new: FileNode) {
        guard let i = children.firstIndex(where: { $0 === old }) else { return }
        children[i] = new
        new.parent = self
        old.parent = nil
        propagate(disk: new.diskSize - old.diskSize,
                  apparent: new.apparentSize - old.apparentSize,
                  items: new.itemCount - old.itemCount,
                  errors: new.errorCount - old.errorCount)
    }

    private func propagate(disk: Int64, apparent: Int64, items: Int, errors: Int) {
        var n: FileNode? = self
        while let c = n {
            c.diskSize += disk
            c.apparentSize += apparent
            c.itemCount += items
            c.errorCount += errors
            n = c.parent
        }
    }

    /// Recompute directory totals bottom-up from each node's own size.
    /// Iterative (reverse pre-order) so deep trees can't overflow the stack.
    /// Precondition: directory nodes hold only their *own* size and error flag.
    static func aggregateTotals(from root: FileNode) {
        var order: [FileNode] = []
        var stack: [FileNode] = [root]
        while let n = stack.popLast() {
            order.append(n)
            for c in n.children where c.isDirectory { stack.append(c) }
        }
        for dir in order.reversed() {
            var disk = dir.diskSize, apparent = dir.apparentSize
            var items = 0, errors = dir.errorCount
            for c in dir.children {
                disk += c.diskSize
                apparent += c.apparentSize
                items += c.itemCount + 1
                errors += c.errorCount
            }
            dir.diskSize = disk
            dir.apparentSize = apparent
            dir.itemCount = items
            dir.errorCount = errors
        }
    }
}
