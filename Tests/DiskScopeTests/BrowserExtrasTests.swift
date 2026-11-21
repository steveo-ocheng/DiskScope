import Foundation
import Testing
@testable import DiskScope

@MainActor
private func memoryModel(_ specs: [String]) -> (AppModel, FileNode) {
    let model = AppModel(trasher: { _ in Issue.record("trasher must not be called") })
    let root = makeTree(rootName: "/mem", specs)
    model.root = root
    model.navigate(to: root)
    return (model, root)
}

@Suite("AppModel · lookups, external Trash, sunburst mode")
@MainActor
struct BrowserExtrasTests {
    @Test func nodeAtPathWalksTheTree() throws {
        let (model, root) = memoryModel(["a/b/c.bin:10", "a/d.bin:5", "e.txt:1"])
        #expect(model.node(atPath: "/mem") === root)
        #expect(model.node(atPath: "/mem/a/b/c.bin") === root.at("a/b/c.bin"))
        #expect(model.node(atPath: "/mem/a") === root["a"])
        #expect(model.node(atPath: "/mem/a/missing") == nil)
        #expect(model.node(atPath: "/memo/a") == nil)       // prefix of the name, not a child
        #expect(model.node(atPath: "/elsewhere/a") == nil)
        model.root = nil
        #expect(model.node(atPath: "/mem/a") == nil)
    }

    @Test func forgetTrashedDetachesAndUpdatesTotals() throws {
        let (model, root) = memoryModel(["a/b/c.bin:10", "a/d.bin:5", "e.txt:1"])
        let a = try #require(root["a"])
        model.navigate(to: try #require(root.at("a/b")))
        let rev = model.revision
        model.forgetTrashed(path: "/mem/a/b/c.bin")
        #expect(root.at("a/b/c.bin") == nil)
        #expect(a.diskSize == 5)
        #expect(root.diskSize == 6)
        #expect(model.revision == rev + 1)

        model.forgetTrashed(path: "/mem/a/b")             // the folder being shown
        #expect(model.current === a)
        model.forgetTrashed(path: "/mem/nope")             // unknown: no-op
        model.forgetTrashed(path: "/mem")                  // never the root
        #expect(model.root === root)
        #expect(model.revision == rev + 2)
    }

    @Test func sunburstActionsUseTheSelectedItem() throws {
        let (model, root) = memoryModel(["a/b/c.bin:10", "e.txt:1"])
        model.viewMode = .sunburst
        defer { model.viewMode = .columns }
        #expect(model.actionTargets.isEmpty)               // never the scan root itself
        let deep = try #require(root.at("a/b/c.bin"))
        model.navigate(to: root, selecting: deep)          // a file several rings out
        #expect(model.actionTargets.map(\.name) == ["c.bin"])
        model.goUp()                                        // first clears the selection…
        #expect(model.selectedFile == nil)
        #expect(model.current === root)
        model.navigate(to: try #require(root["a"]))
        #expect(model.actionTargets.map(\.name) == ["a"])
        model.goUp()                                        // …then goes up
        #expect(model.current === root)
    }

    @Test func folderScansHaveNoHiddenSpace() async throws {
        let t = TempTree("hs-folder")
        t.file("x.bin", bytes: 100)
        let model = AppModel(trasher: FakeTrash().trasher)
        model.scan(t.root)
        try await waitForScan(model)
        try await waitUntil { model.volume != nil }
        #expect(model.hiddenSpace == nil)
        model.closeScan()
        #expect(model.volume == nil)
    }
}
