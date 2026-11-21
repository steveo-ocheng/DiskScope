import Foundation
import Darwin
import Testing
@testable import DiskScope

/// Model backed by an in-memory tree (no disk access): for navigation, sorting, search.
@MainActor
private func modelWithTree(_ specs: [String], rootName: String = "/mem") -> (AppModel, FileNode) {
    let model = AppModel(trasher: { _ in Issue.record("trasher must not be called") })
    let root = makeTree(rootName: rootName, specs)
    model.root = root
    model.navigate(to: root)
    return (model, root)
}

private let standardSpecs = ["a/b/c/deep.bin:10", "a/big.bin:500", "a/small.txt:3", "z/mid.dat:200", "top.txt:50"]

@Suite("AppModel · scanning")
@MainActor
struct AppModelScanTests {
    @Test func scanBuildsTreeAndStartsBrowsing() async throws {
        let t = TempTree("m-scan")
        t.file("a/f.bin", bytes: 1_000)
        let model = AppModel(trasher: FakeTrash().trasher)
        model.scan(t.root)
        #expect(model.phase == .scanning)
        #expect(model.scanTarget == t.root)
        try await waitForScan(model)
        let root = try #require(model.root)
        #expect(model.phase == .browsing)
        #expect(root.path == t.root)
        #expect(model.current === root)
        #expect(!model.canGoBack && !model.canGoForward)
        #expect(model.revision > 0)
        #expect(root.at("a/f.bin")?.apparentSize == 1_000)
        try await waitUntil { model.volume != nil }
        #expect(model.volume!.total > 0)
    }

    @Test func scanCanonicalizesSymlinkedAndRelativeRoots() async throws {
        let t = TempTree("m-canon")
        t.file("real/x.txt", bytes: 5)
        let link = t.symlink("alias", to: t.path("real"))
        let model = AppModel(trasher: FakeTrash().trasher)
        model.scan(link + "/../alias/.")
        try await waitForScan(model)
        #expect(model.root?.path == t.path("real"))   // symlink and ".." resolved

        // /tmp is itself a symlink to /private/tmp.
        let tmpDir = "/tmp/DiskScopeTests-canon-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: "/private" + tmpDir) }
        model.scan(tmpDir)
        try await waitForScan(model)
        #expect(model.root?.path == "/private" + tmpDir)
    }

    @Test func scanningAVolumeScansItsPath() async throws {
        let t = TempTree("m-vol")
        t.file("q.bin", bytes: 10)
        let volume = try #require(Volume(url: URL(fileURLWithPath: t.root)))
        let model = AppModel(trasher: FakeTrash().trasher)
        model.scan(volume)
        try await waitForScan(model)
        #expect(model.root?.path == t.root)
    }

    @Test func missingPathShowsAlertWithoutScanning() {
        let model = AppModel(trasher: FakeTrash().trasher)
        model.scan("~/DiskScopeTests-definitely-missing-\(UUID().uuidString)")
        #expect(model.phase == .idle)
        #expect(model.root == nil)
        #expect(model.alert?.title.hasPrefix("Can't scan") == true)
        #expect(model.alert?.message.contains(NSHomeDirectory()) == true)   // "~" expanded
    }

    @Test func fileRootShowsAlert() {
        let t = TempTree("m-file")
        let f = t.file("not-a-folder.txt", bytes: 1)
        let model = AppModel(trasher: FakeTrash().trasher)
        model.scan(f)
        #expect(model.alert?.message.contains("is not a folder") == true)
        #expect(model.phase == .idle)
    }

    @Test(.enabled(if: getuid() != 0, "root bypasses permissions"))
    func unreadableRootReportsScanFailure() async throws {
        let t = TempTree("m-locked")
        let locked = t.dir("locked")
        chmod(locked, 0o000)
        let model = AppModel(trasher: FakeTrash().trasher)
        model.scan(locked)
        try await waitForScan(model)
        #expect(model.alert?.title == "Scan failed")
        #expect(model.alert?.message.contains("Full Disk Access") == true)
        #expect(model.phase == .idle)
        #expect(model.root == nil)
    }

    @Test func cancelledScanIsDiscarded() async throws {
        let t = TempTree("m-cancel")
        for i in 0..<200 { t.file("d\(i % 10)/f\(i)", bytes: 10) }
        let model = AppModel(trasher: FakeTrash().trasher)
        model.scan(t.root)
        model.cancelScan()
        #expect(model.phase == .idle)
        try await Task.sleep(for: .milliseconds(400))   // let the background scan finish
        #expect(model.root == nil)
        #expect(model.phase == .idle)
    }

    @Test func cancellingARescanReturnsToBrowsing() async throws {
        let t = TempTree("m-cancel2")
        t.file("a/f", bytes: 1)
        let model = AppModel(trasher: FakeTrash().trasher)
        model.scan(t.root)
        try await waitForScan(model)
        model.navigate(to: model.root!["a"]!)   // rescanning a subfolder keeps the tree
        model.rescanCurrent()
        #expect(model.phase == .scanning)
        model.cancelScan()
        #expect(model.phase == .browsing)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.current?.name == "a")
    }

    @Test func newScanAndCloseScanResetEverything() async throws {
        let t = TempTree("m-reset")
        t.file("a/f.bin", bytes: 10)
        let model = AppModel(trasher: FakeTrash().trasher)
        model.scan(t.root)
        try await waitForScan(model)
        model.navigate(to: model.root!["a"]!)
        model.searchText = "f"
        #expect(model.canGoBack)

        model.scan(t.root)   // rescan from scratch
        #expect(model.root == nil && model.current == nil)   // old tree released immediately
        #expect(model.searchText.isEmpty && !model.canGoBack)
        try await waitForScan(model)
        #expect(model.root != nil)

        model.closeScan()
        #expect(model.phase == .idle)
        #expect(model.root == nil && model.current == nil && model.volume == nil)
        #expect(!model.canGoBack && !model.canGoForward)
    }

    @Test func rescanOfRootDoesAFullScan() async throws {
        let t = TempTree("m-rescanroot")
        t.file("f.bin", bytes: 10)
        let model = AppModel(trasher: FakeTrash().trasher)
        model.scan(t.root)
        try await waitForScan(model)
        let first = model.root
        t.file("g.bin", bytes: 20)
        model.rescanCurrent()
        try await waitForScan(model)
        #expect(model.root !== first)
        #expect(model.root?["g.bin"]?.apparentSize == 20)
        _ = first   // keep old tree alive until here
    }

    @Test func rescanWithNothingShownIsNoOp() {
        let model = AppModel(trasher: FakeTrash().trasher)
        model.rescanCurrent()
        #expect(model.phase == .idle)
    }

    @Test func rescanSplicesSubtreeAndPurgesStaleHistory() async throws {
        let t = TempTree("m-rescan")
        t.file("a/b/old.bin", bytes: 1_000)
        t.file("other.bin", bytes: 7)
        let model = AppModel(trasher: FakeTrash().trasher)
        model.viewMode = .columns
        model.scan(t.root)
        try await waitForScan(model)
        let root = try #require(model.root)
        let a = try #require(root["a"])
        model.navigate(to: a)
        model.navigate(to: try #require(a["b"]))
        model.goBack()                       // at a; history: root, a, b
        #expect(model.current === a && model.canGoForward)

        t.file("a/new.bin", bytes: 50_000)
        let before = root.apparentSize
        model.rescanCurrent()
        try await waitForScan(model)

        let freshA = try #require(model.current)
        #expect(freshA !== a)
        #expect(freshA.name == "a")
        #expect(freshA.parent === root)
        #expect(root["a"] === freshA)
        #expect(freshA.path == t.path("a"))
        #expect(root.apparentSize >= before + 50_000)   // (+ the folder entry's own size change)
        #expect(freshA["new.bin"]?.apparentSize == 50_000)
        #expect(root.itemCount == 5)
        #expect(!model.canGoForward)          // "b" (inside the replaced subtree) was purged
        model.goBack()
        #expect(model.current === root)
        model.goForward()
        #expect(model.current === freshA)
    }

    @Test func rescanResultIsDroppedIfFolderWasRemovedMeanwhile() async throws {
        let t = TempTree("m-rescan-trashed")
        t.file("a/f.bin", bytes: 10)
        let trash = FakeTrash()
        let model = AppModel(trasher: trash.trasher)
        model.viewMode = .columns
        model.scan(t.root)
        try await waitForScan(model)
        let root = try #require(model.root)
        let a = try #require(root["a"])
        model.navigate(to: a)
        model.rescanCurrent()
        // Same main-actor turn: the rescan can't complete before we trash the folder.
        model.requestTrash([a])
        model.confirmTrash()
        try await waitForScan(model)
        #expect(root["a"] == nil)
        #expect(model.current === root)
        #expect(model.phase == .browsing)
    }
}

@Suite("AppModel · navigation")
@MainActor
struct AppModelNavigationTests {
    @Test func navigateRecordsHistoryOnlyForNewFolders() {
        let (model, root) = modelWithTree(standardSpecs)
        let a = root["a"]!, z = root["z"]!
        #expect(!model.canGoBack)
        model.navigate(to: a)
        model.navigate(to: a)                 // same folder: no new entry
        model.navigate(to: z, record: false)  // not recorded
        #expect(model.current === z)
        model.goBack()
        #expect(model.current === root)
        #expect(model.canGoForward)
        model.goForward()
        #expect(model.current === a)
        #expect(!model.canGoForward)
    }

    @Test func navigatingAfterGoingBackDropsForwardHistory() {
        let (model, root) = modelWithTree(standardSpecs)
        model.navigate(to: root["a"]!)
        model.goBack()
        model.navigate(to: root["z"]!)
        #expect(!model.canGoForward)
        model.goBack()
        #expect(model.current === root)
    }

    @Test func backAndForwardStopAtTheEnds() {
        let (model, root) = modelWithTree(standardSpecs)
        model.goBack()
        #expect(model.current === root)
        model.goForward()
        #expect(model.current === root)
    }

    @Test func historyIsCappedAt200Entries() {
        let (model, root) = modelWithTree(standardSpecs)
        let a = root["a"]!, z = root["z"]!
        for i in 0..<250 { model.navigate(to: i.isMultiple(of: 2) ? a : z) }
        var steps = 0
        while model.canGoBack { model.goBack(); steps += 1 }
        #expect(steps == 199)
    }

    @Test func historySkipsFoldersNoLongerInTheTree() {
        let (model, oldRoot) = modelWithTree(standardSpecs)
        let a = oldRoot["a"]!
        model.navigate(to: a)
        // Swap in an unrelated tree without resetting history (old nodes stay alive via oldRoot).
        let other = makeTree(rootName: "/other", ["q:1"])
        model.root = other
        model.goBack()                         // both entries are detached → skipped
        #expect(model.current === a)           // nothing valid to go back to
        #expect(!model.canGoBack)              // regression: index used to stay past the end
        _ = (oldRoot, other)
    }

    @Test func selectingFoldersAndFilesInColumns() {
        let (model, root) = modelWithTree(standardSpecs)
        model.viewMode = .columns
        let a = root["a"]!, big = a["big.bin"]!
        model.select(a, in: root)
        #expect(model.current === a && model.selectedFile == nil)
        model.select(big, in: a)
        #expect(model.current === a && model.selectedFile === big)
        #expect(model.actionTargets.map(\.name) == ["big.bin"])

        model.goUp()                           // first ←/⌘↑ just deselects the file
        #expect(model.selectedFile == nil && model.current === a)
        #expect(model.actionTargets.first === a)   // folder itself is the target
        model.goUp()
        #expect(model.current === root)
        #expect(model.actionTargets.isEmpty)       // never target the scan root
        model.goUp()
        #expect(model.current === root)
    }

    @Test func goUpInListModeIgnoresFileSelection() {
        let (model, root) = modelWithTree(standardSpecs)
        model.viewMode = .list
        let a = root["a"]!
        model.navigate(to: a, selecting: a["big.bin"]!)
        model.goUp()
        #expect(model.current === root)
    }

    @Test func goUpWithNothingLoadedIsSafe() {
        let model = AppModel(trasher: { _ in })
        model.goUp()
        model.goBack()
        model.goForward()
        #expect(model.current == nil)
        #expect(model.actionTargets.isEmpty)
    }

    @Test func revealInBrowserSelectsItemAndClearsSearch() {
        let (model, root) = modelWithTree(standardSpecs)
        let deep = root.at("a/b/c/deep.bin")!
        model.searchText = "deep"
        model.reveal(inBrowser: deep)
        #expect(model.searchText.isEmpty)
        #expect(model.current === root.at("a/b/c"))
        #expect(model.selectedFile === deep)
        #expect(model.listSelection == [deep.id])

        model.reveal(inBrowser: root["z"]!)
        #expect(model.current === root["z"])
        #expect(model.selectedFile == nil)

        let orphan = FileNode(name: "o", isDirectory: false, isSymlink: false, diskSize: 0, apparentSize: 0, mtime: 0, parent: nil)
        model.reveal(inBrowser: orphan)        // no parent: ignored
        #expect(model.current === root["z"])
    }

    @Test func openingAFolderNavigatesIntoIt() {
        let (model, root) = modelWithTree(standardSpecs)
        model.open(root["a"]!)
        #expect(model.current === root["a"])
    }

    @Test func listSelectionDrivesActionTargetsInListMode() {
        let (model, root) = modelWithTree(standardSpecs)
        model.viewMode = .list
        let a = root["a"]!, top = root["top.txt"]!
        model.listSelection = [a.id, top.id]
        #expect(Set(model.actionTargets.map(\.name)) == ["a", "top.txt"])
        model.navigate(to: a)
        #expect(model.listSelection.isEmpty)   // cleared on folder change
        #expect(model.actionTargets.isEmpty)
    }

    @Test func viewModeIsPersisted() {
        let saved = UserDefaults.standard.string(forKey: "viewMode")
        defer { UserDefaults.standard.set(saved, forKey: "viewMode") }
        let model = AppModel(trasher: { _ in })
        model.viewMode = .list
        #expect(UserDefaults.standard.string(forKey: "viewMode") == "list")
        #expect(AppModel(trasher: { _ in }).viewMode == .list)
        model.viewMode = .columns
        #expect(AppModel(trasher: { _ in }).viewMode == .columns)
    }
}

@Suite("AppModel · sorting")
@MainActor
struct AppModelSortingTests {
    @Test func defaultSortIsLargestFirst() {
        let (model, root) = modelWithTree(standardSpecs)
        #expect(model.sortKey == .size)
        #expect(model.sortedChildren(of: root).map(\.name) == ["a", "z", "top.txt"])
    }

    @Test func everySortKeyRoundTrips() {
        let (model, root) = modelWithTree(["f10:1", "f2:3", "dir/x:1", "dir/y:1", "g:2"])
        model.setSort(.name)
        #expect(model.sortKey == .name)
        #expect(model.sortedChildren(of: root).map(\.name) == ["dir", "f2", "f10", "g"])   // natural order
        model.setSort(.items)
        #expect(model.sortKey == .items)
        #expect(model.sortedChildren(of: root).first?.name == "dir")
        model.setSort(.modified)
        #expect(model.sortKey == .modified)
        model.setSort(.size)
        #expect(model.sortKey == .size)
    }

    @Test func identifiersAreStable() {
        #expect(SortKey.allCases.map(\.id) == ["Size", "Name", "Items", "Date Modified"])
        #expect(ViewMode.allCases == [.list, .columns])
        let a = AlertInfo(title: "t", message: "m"), b = AlertInfo(title: "t", message: "m")
        #expect(a.id != b.id)
    }

    @Test func unknownSortOrderHasNoKey() {
        let (model, _) = modelWithTree(standardSpecs)
        model.sortOrder = [KeyPathComparator(\FileNode.errorCount)]
        #expect(model.sortKey == nil)
        model.sortOrder = []
        #expect(model.sortKey == nil)
    }

    @Test func apparentSizeTogglesSizeAndSortKeyPath() {
        let (model, root) = modelWithTree(standardSpecs)
        let a = root["a"]!
        a.apparentSize = 1        // make disk and apparent orders differ
        #expect(model.size(of: a) == a.diskSize)
        model.showApparentSize = true
        #expect(model.size(of: a) == 1)
        #expect(model.sortKey == .size)
        #expect(model.sortOrder.first.map { $0.keyPath == \FileNode.apparentSize } == true)
        #expect(model.sortedChildren(of: root).last === a)
        model.setSort(.name)
        model.showApparentSize = false     // not sorting by size: order untouched
        #expect(model.sortKey == .name)
    }

    @Test func sortedChildrenIsCachedUntilTheTreeChanges() {
        let (model, root) = modelWithTree(standardSpecs)
        let first = model.sortedChildren(of: root)
        let extra = FileNode(name: "huge", isDirectory: false, isSymlink: false, diskSize: 10_000, apparentSize: 10_000, mtime: 0, parent: root)
        root.children.append(extra)
        #expect(model.sortedChildren(of: root).map(\.name) == first.map(\.name))   // cached
        model.revision += 1
        #expect(model.sortedChildren(of: root).first === extra)
    }
}

@Suite("AppModel · search")
@MainActor
struct AppModelSearchTests {
    @Test func emptyOrBlankQueryClearsResults() async {
        let (model, _) = modelWithTree(standardSpecs)
        model.searchText = "   "
        await model.performSearch()
        #expect(model.searchResults.isEmpty && model.searchMatchCount == 0 && !model.searching)
    }

    @Test func searchFindsMatchesLargestFirstAcrossTheScan() async {
        let (model, root) = modelWithTree(["a/report-1.pdf:10", "b/c/REPORT-2.pdf:900", "z/Report.dir/x:5", "other.txt:1"])
        model.navigate(to: root["a"]!)
        model.searchText = "report"
        await model.performSearch()
        #expect(model.searchResults.map(\.name) == ["REPORT-2.pdf", "report-1.pdf", "Report.dir"])
        #expect(model.searchMatchCount == 3)
        #expect(model.searchSelection.isEmpty)

        model.searchWholeScan = false          // only inside the current folder
        await model.performSearch()
        #expect(model.searchResults.map(\.name) == ["report-1.pdf"])
    }

    @Test func searchIgnoresCaseAndDiacritics() async {
        let (model, _) = modelWithTree(["Café Photos/x:1", "resume.doc:2"])
        model.searchText = "cafe"
        await model.performSearch()
        #expect(model.searchResults.map(\.name) == ["Café Photos"])
        model.searchText = "RÉSUMÉ"
        await model.performSearch()
        #expect(model.searchResults.map(\.name) == ["resume.doc"])
    }

    @Test func resultsAreCappedButAllMatchesCounted() async {
        let specs = (0..<1_100).map { "dir\($0 % 7)/match\($0):\($0)" }
        let (model, _) = modelWithTree(specs)
        model.searchText = "match"
        await model.performSearch()
        #expect(model.searchResults.count == AppModel.searchResultLimit)
        #expect(model.searchMatchCount == 1_100)
        #expect(model.searchResults.first?.name == "match1099")
    }

    @Test func searchTargetsAreTheSelectedResults() async {
        let (model, _) = modelWithTree(standardSpecs)
        model.searchText = "bin"
        await model.performSearch()
        let pick = model.searchResults[0]
        model.searchSelection = [pick.id]
        #expect(model.actionTargets.map(\.name) == [pick.name])
    }

    @Test func cancelledSearchLeavesPreviousResults() async {
        let specs = (0..<25_000).map { "d\($0 % 50)/f\($0):1" }
        let (model, _) = modelWithTree(specs)
        model.searchText = "f"
        let task = Task { await model.performSearch() }
        task.cancel()
        await task.value
        #expect(model.searchResults.isEmpty)   // abandoned at the first yield
        #expect(!model.searching)
    }

    @Test func searchWithoutATreeIsEmpty() async {
        let model = AppModel(trasher: { _ in })
        model.searchText = "x"
        await model.performSearch()
        #expect(model.searchResults.isEmpty)
    }
}
