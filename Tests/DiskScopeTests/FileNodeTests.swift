import Foundation
import Testing
@testable import DiskScope

@Suite("FileNode")
struct FileNodeTests {
    @Test func pathJoinsNamesFromRoot() {
        let root = makeTree(rootName: "/r", ["a/b/f:10"])
        #expect(root.at("a/b/f")?.path == "/r/a/b/f")
        #expect(root.path == "/r")

        let slashRoot = makeTree(rootName: "/", ["x/y:1"])
        #expect(slashRoot.at("x/y")?.path == "/x/y")   // no "//"
    }

    @Test func ancestryRunsRootToNode() {
        let root = makeTree(rootName: "/r", ["a/b/f:10"])
        let f = root.at("a/b/f")!
        #expect(f.ancestry.map(\.name) == ["/r", "a", "b", "f"])
        #expect(root.ancestry.count == 1)
    }

    @Test func aggregateTotalsSumsSizesItemsAndErrors() {
        let root = makeTree(rootName: "/r", ["a/f1:100", "a/f2:50", "b/c/f3:7", "empty/"])
        #expect(root.diskSize == 157)
        #expect(root.apparentSize == 157)
        #expect(root["a"]!.diskSize == 150)
        #expect(root.errorCount == 0)
    }

    @Test func aggregateTotalsCountsEveryDescendant() {
        // a, a/f1, a/f2, b, b/c, b/c/f3, empty  → 7 descendants
        let root = makeTree(rootName: "/r", ["a/f1:100", "a/f2:50", "b/c/f3:7", "empty/"])
        #expect(root.itemCount == 7)
        #expect(root["a"]!.itemCount == 2)
        #expect(root["empty"]!.itemCount == 0)
        #expect(root.at("a/f1")!.itemCount == 0)
    }

    @Test func aggregateTotalsIncludesErrorsAndOwnDirectorySize() {
        let root = FileNode(name: "/r", isDirectory: true, isSymlink: false,
                            diskSize: 4096, apparentSize: 64, mtime: 0, parent: nil)
        let dir = FileNode(name: "d", isDirectory: true, isSymlink: false,
                           diskSize: 4096, apparentSize: 64, mtime: 0, parent: root)
        dir.errorCount = 1   // unreadable directory
        let bad = FileNode(name: "bad", isDirectory: false, isSymlink: false,
                           diskSize: 0, apparentSize: 0, mtime: 0, parent: root)
        bad.errorCount = 1
        root.children = [dir, bad]
        FileNode.aggregateTotals(from: root)
        #expect(root.diskSize == 8192)
        #expect(root.apparentSize == 128)
        #expect(root.errorCount == 2)
        #expect(root.itemCount == 2)
    }

    @Test func removePropagatesToAllAncestors() {
        let root = makeTree(rootName: "/r", ["a/b/f:100", "a/g:5", "x:1"])
        let a = root["a"]!, b = a["b"]!, f = b["f"]!
        b.remove(f)
        #expect(f.parent == nil)
        #expect(b.children.isEmpty)
        #expect(b.diskSize == 0 && a.diskSize == 5 && root.diskSize == 6)
        #expect(root.apparentSize == 6)
        #expect(b.itemCount == 0 && a.itemCount == 2 && root.itemCount == 4)
    }

    @Test func removeSubtractsErrorsAndWholeSubtreeCount() {
        let root = makeTree(rootName: "/r", ["a/b/f:100", "x:1"])
        let a = root["a"]!
        a.errorCount = 3
        root.errorCount = 3
        root.remove(a)
        #expect(root.itemCount == 1)   // only x remains
        #expect(root.errorCount == 0)
        #expect(root.diskSize == 1)
    }

    @Test func removeOfNonChildIsNoOp() {
        let root = makeTree(rootName: "/r", ["a/f:10"])
        let stranger = FileNode(name: "s", isDirectory: false, isSymlink: false,
                                diskSize: 99, apparentSize: 99, mtime: 0, parent: nil)
        root.remove(stranger)
        #expect(root.diskSize == 10 && root.itemCount == 2)
    }

    @Test func replacePropagatesDeltasAndReparents() {
        let root = makeTree(rootName: "/r", ["a/f:10", "x:1"])
        let old = root["a"]!
        let fresh = makeTree(rootName: "/r/a", ["f:10", "g:30", "h:5"])
        fresh.errorCount = 2
        fresh.name = "a"
        root.replace(old, with: fresh)
        #expect(old.parent == nil)
        #expect(fresh.parent === root)
        #expect(root["a"] === fresh)
        #expect(root.diskSize == 46)
        #expect(root.itemCount == 5)   // a, f, g, h, x
        #expect(root.errorCount == 2)
        #expect(fresh.at("g")!.path == "/r/a/g")
    }

    @Test func replaceOfNonChildIsNoOp() {
        let root = makeTree(rootName: "/r", ["a/f:10"])
        let stranger = makeTree(rootName: "s", ["q:5"])
        root.replace(stranger, with: makeTree(rootName: "t", ["z:1"]))
        #expect(root.diskSize == 10 && root.children.count == 1)
    }

    @Test func modifiedRoundTripsAndClamps() {
        func node(_ d: Date) -> FileNode {
            FileNode(name: "f", isDirectory: false, isSymlink: false, diskSize: 0, apparentSize: 0, modified: d, parent: nil)
        }
        #expect(node(.distantPast).modified == .distantPast)
        let t = Date(timeIntervalSince1970: 1_700_000_123)
        #expect(node(t).modified == t)
        #expect(node(Date(timeIntervalSince1970: -50)).modified == .distantPast)  // clamps to 0 = unknown

        let viaMtime = FileNode(name: "f", isDirectory: false, isSymlink: false,
                                diskSize: 0, apparentSize: 0, mtime: 1_600_000_000, parent: nil)
        #expect(viaMtime.modified == Date(timeIntervalSince1970: 1_600_000_000))
        let zero = FileNode(name: "f", isDirectory: false, isSymlink: false,
                            diskSize: 0, apparentSize: 0, mtime: 0, parent: nil)
        #expect(zero.modified == .distantPast)
        let huge = FileNode(name: "f", isDirectory: false, isSymlink: false,
                            diskSize: 0, apparentSize: 0, mtime: Int.max, parent: nil)
        #expect(huge.modified == Date(timeIntervalSince1970: TimeInterval(UInt32.max)))
    }

    @Test func countersClampToUInt32Range() {
        let n = FileNode(name: "d", isDirectory: true, isSymlink: false, diskSize: 0, apparentSize: 0, mtime: 0, parent: nil)
        n.itemCount = -5
        #expect(n.itemCount == 0)
        n.errorCount = Int.max
        #expect(n.errorCount == Int(UInt32.max))
    }

    @Test func identityIsPerObject() {
        let a = makeTree(rootName: "/a", [])
        let b = makeTree(rootName: "/a", [])
        #expect(a.id != b.id)
        #expect(a.id == a.id)
    }

    @Test func deepTreeTeardownDoesNotOverflowStack() {
        // A recursive deinit would need ~300k nested frames and crash.
        do {
            let root = FileNode(name: "/deep", isDirectory: true, isSymlink: false, diskSize: 0, apparentSize: 0, mtime: 0, parent: nil)
            var cur = root
            for i in 0..<300_000 {
                let n = FileNode(name: "d\(i)", isDirectory: true, isSymlink: false, diskSize: 1, apparentSize: 1, mtime: 0, parent: cur)
                cur.children = [n]
                cur = n
            }
            FileNode.aggregateTotals(from: root)   // iterative as well
            #expect(root.itemCount == 300_000)
            #expect(root.diskSize == 300_000)
        }
        // Reaching here means teardown completed.
    }

    @Test func nodeHeldElsewhereKeepsItsChildrenWhenTreeIsReleased() {
        var keptChildNames: [String] = []
        let survivor: FileNode
        do {
            let root = makeTree(rootName: "/r", ["a/b/c:1", "z:2"])
            survivor = root["a"]!
        }
        // `root` is gone; `a` is still owned here and must not have been dismantled.
        // (Don't read survivor.parent: it's unowned and its parent was freed.)
        keptChildNames = survivor.children.map(\.name)
        #expect(keptChildNames == ["b"])
        #expect(survivor.children[0].children.map(\.name) == ["c"])
    }
}
