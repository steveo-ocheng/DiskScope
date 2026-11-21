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

    @Test func csvExportOfFolderAndWholeScan() async throws {
        let (model, root) = memoryModel(["a/b/c.bin:10", "a/=evil,name.txt:5", "e.txt:1"])
        let dir = TempTree("csv")
        let folderURL = URL(fileURLWithPath: dir.path("folder.csv"))
        try await model.writeCSV(.folder, to: folderURL)
        let folder = try String(contentsOf: folderURL, encoding: .utf8)
        let rows = folder.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(rows.first == ScanCSV.header.joined(separator: ","))
        #expect(rows.count == 3)                                   // header + a + e.txt
        #expect(rows[1].hasPrefix("/mem/a,a,folder,15,15,3,"))     // largest first; items inside a
        #expect(rows[2].hasPrefix("/mem/e.txt,e.txt,file,1,1,1,"))

        model.navigate(to: try #require(root["a"]))
        let allURL = URL(fileURLWithPath: dir.path("all.csv"))
        try await model.writeCSV(.all, to: allURL)                  // whole scan, regardless of the folder shown
        let all = try String(contentsOf: allURL, encoding: .utf8)
        let allRows = all.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(allRows.count == 1 + root.allNodes.count)
        #expect(allRows[1].hasPrefix("/mem,/mem,folder,16,16,"))
        // A name that looks like a formula and contains a comma is neutralised and quoted.
        #expect(all.contains("\"/mem/a/=evil,name.txt\",\"'=evil,name.txt\",file,5,5,1,"))
        #expect(!model.exporting)
    }

    @Test func csvRowFormatsDatesAndErrors() {
        let node = FileNode(name: "x", isDirectory: false, isSymlink: true, diskSize: 0, apparentSize: 3,
                            mtime: 1_700_000_000, parent: nil)
        node.errorCount = 1
        let row = ScanCSV.row(node, path: "/p/x")
        #expect(row == "/p/x,x,symlink,0,3,1,2023-11-14T22:13:20Z,1\r\n")
        let undated = FileNode(name: "y", isDirectory: true, isSymlink: false, diskSize: 0, apparentSize: 0,
                               mtime: 0, parent: nil)
        #expect(ScanCSV.row(undated, path: "/y") == "/y,y,folder,0,0,0,,0\r\n")
    }
}
