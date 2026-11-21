import Foundation
import Darwin
import Testing
@testable import DiskScope

/// Scans a temp tree into a model whose "Trash" is a fake that only deletes inside test dirs.
@MainActor
private func scannedModel(_ t: TempTree, trash: FakeTrash = FakeTrash()) async throws -> (AppModel, FileNode) {
    let model = AppModel(trasher: trash.trasher)
    model.viewMode = .columns
    model.scan(t.root)
    try await waitForScan(model)
    return (model, try #require(model.root))
}

@Suite("Trash flow")
@MainActor
struct TrashFlowTests {
    @Test func trashingAFileRemovesItAndUpdatesTotals() async throws {
        let t = TempTree("tr-ok")
        t.file("a/victim.bin", bytes: 40_000)
        t.file("a/keep.bin", bytes: 10)
        let trash = FakeTrash()
        let (model, root) = try await scannedModel(t, trash: trash)
        let victim = try #require(root.at("a/victim.bin"))
        let (disk, items, rev) = (root.diskSize, root.itemCount, model.revision)

        model.requestTrash([victim])
        #expect(model.pendingTrash.map(\.name) == ["victim.bin"])
        model.confirmTrash()

        #expect(trash.trashed == [t.path("a/victim.bin")])
        #expect(!FileManager.default.fileExists(atPath: t.path("a/victim.bin")))
        #expect(root.at("a/victim.bin") == nil)
        #expect(root.diskSize == disk - victim.diskSize)
        #expect(root.itemCount == items - 1)
        #expect(model.pendingTrash.isEmpty)
        #expect(model.revision > rev)
        #expect(model.alert == nil)
    }

    @Test func trashingTheShownFolderMovesTheViewOut() async throws {
        let t = TempTree("tr-current")
        t.file("a/b/f.bin", bytes: 10)
        t.file("x.bin", bytes: 1)
        let trash = FakeTrash()
        let (model, root) = try await scannedModel(t, trash: trash)
        let a = try #require(root["a"])
        model.navigate(to: a)
        model.navigate(to: try #require(a["b"]))
        model.select(try #require(a.at("b/f.bin")), in: a["b"]!)

        model.requestTrash([a])
        model.confirmTrash()
        #expect(model.current === root)
        #expect(model.selectedFile == nil)
        #expect(!model.canGoForward)
        model.goBack()                       // history no longer holds anything inside "a"
        #expect(model.current === root)
        #expect(root.itemCount == 1)
    }

    @Test func nestedSelectionsCollapseToTheOutermostFolder() async throws {
        let t = TempTree("tr-nested")
        t.file("a/f.bin", bytes: 10)
        t.file("a/g.bin", bytes: 10)
        let (model, root) = try await scannedModel(t)
        let a = try #require(root["a"])
        model.requestTrash([a["f.bin"]!, a, a["g.bin"]!])
        #expect(model.pendingTrash.count == 1)
        #expect(model.pendingTrash.first === a)
    }

    @Test func scanRootAloneIsNeverTrashed() async throws {
        let t = TempTree("tr-root")
        t.file("f", bytes: 1)
        let (model, root) = try await scannedModel(t)
        model.requestTrash([root])
        #expect(model.pendingTrash.isEmpty)
        #expect(model.alert == nil)
    }

    @Test func protectedLocationsAreRefused() {
        let model = AppModel(trasher: { _ in Issue.record("must not trash") })
        let root = makeTree(rootName: "/", ["Applications/X.app/c:1", "System/Library/k:1", "Users/u/f:1"])
        model.root = root
        model.requestTrash([root["Applications"]!, root.at("Users/u/f")!])
        #expect(model.alert?.title == "Protected item")
        #expect(model.alert?.message.contains("/Applications") == true)
        #expect(model.pendingTrash.isEmpty)

        model.alert = nil
        model.requestTrash([root.at("System/Library")!])
        #expect(model.alert?.title == "Protected item")
    }

    @Test(.enabled(if: getuid() != 0, "root bypasses permissions"))
    func itemsThatFailedDuringTheScanAreRefused() async throws {
        let t = TempTree("tr-unreliable")
        t.file("rdonly/a.bin", bytes: 10)
        chmod(t.path("rdonly"), 0o444)
        let (model, root) = try await scannedModel(t)
        let bad = try #require(root.at("rdonly/a.bin"))
        #expect(TrashGuard.isUnreliable(bad))
        model.requestTrash([bad])
        #expect(model.alert?.title == "Can't move to Trash")
        #expect(model.pendingTrash.isEmpty)
    }

    @Test func goneItemsAreDroppedWithoutTrashing() async throws {
        let t = TempTree("tr-gone")
        t.file("a/f.bin", bytes: 10)
        let trash = FakeTrash()
        let (model, root) = try await scannedModel(t, trash: trash)
        let f = try #require(root.at("a/f.bin"))
        try FileManager.default.removeItem(atPath: t.path("a/f.bin"))
        model.requestTrash([f])
        model.confirmTrash()
        #expect(trash.trashed.isEmpty)
        #expect(root.at("a/f.bin") == nil)
        #expect(model.alert == nil)
    }

    @Test func goneParentFolderAlsoCountsAsGone() async throws {
        let t = TempTree("tr-gone2")
        t.file("a/b/f.bin", bytes: 10)
        let trash = FakeTrash()
        let (model, root) = try await scannedModel(t, trash: trash)
        let f = try #require(root.at("a/b/f.bin"))
        try FileManager.default.removeItem(atPath: t.path("a"))
        #expect(TrashGuard.verify(f) == .gone)
        model.requestTrash([f])
        model.confirmTrash()
        #expect(trash.trashed.isEmpty)
        #expect(root.at("a/b/f.bin") == nil)
    }

    @Test func itemThatChangedKindIsRefused() async throws {
        let t = TempTree("tr-kind")
        t.file("a/thing", bytes: 10)
        let trash = FakeTrash()
        let (model, root) = try await scannedModel(t, trash: trash)
        let thing = try #require(root.at("a/thing"))
        try FileManager.default.removeItem(atPath: t.path("a/thing"))
        t.dir("a/thing")                       // now a folder at the same path
        model.requestTrash([thing])
        model.confirmTrash()
        #expect(trash.trashed.isEmpty)
        #expect(model.alert?.title == "Couldn't move to Trash")
        #expect(model.alert?.message.contains("changed since the scan") == true)
        #expect(root.at("a/thing") === thing)  // kept in the tree
    }

    @Test func fileModifiedAfterTheScanIsRefused() async throws {
        let t = TempTree("tr-modified")
        let p = t.file("doc.txt", bytes: 100)
        let past = timeval(tv_sec: 1_600_000_000, tv_usec: 0)
        _ = [past, past].withUnsafeBufferPointer { utimes(p, $0.baseAddress) }
        let trash = FakeTrash()
        let (model, root) = try await scannedModel(t, trash: trash)
        let doc = try #require(root["doc.txt"])

        // Different content, same size: caught by the mtime check.
        FileManager.default.createFile(atPath: p, contents: Data(repeating: 0x42, count: 100))
        #expect(TrashGuard.verify(doc) == .changedKind)
        model.requestTrash([doc])
        model.confirmTrash()
        #expect(trash.trashed.isEmpty)
        #expect(model.alert?.message.contains("changed since the scan") == true)
    }

    @Test func folderTouchedAfterTheScanCanStillBeTrashed() async throws {
        let t = TempTree("tr-dirtouch")
        t.file("a/f.bin", bytes: 10)
        let trash = FakeTrash()
        let (model, root) = try await scannedModel(t, trash: trash)
        let a = try #require(root["a"])
        t.file("a/.DS_Store", bytes: 6_148)   // Finder-style write changes the folder's mtime
        #expect(TrashGuard.verify(a) == .ok)
        model.requestTrash([a])
        model.confirmTrash()
        #expect(trash.trashed == [t.path("a")])
    }

    @Test func enclosingFolderSwappedForASymlinkIsRefused() async throws {
        let t = TempTree("tr-swap")
        t.file("a/f.bin", bytes: 10)
        let elsewhere = TempTree("tr-elsewhere")
        elsewhere.file("f.bin", bytes: 10)    // same name/size, different file
        let trash = FakeTrash()
        let (model, root) = try await scannedModel(t, trash: trash)
        let f = try #require(root.at("a/f.bin"))
        try FileManager.default.moveItem(atPath: t.path("a"), toPath: t.path("a-moved"))
        t.symlink("a", to: elsewhere.root)    // ".../a/f.bin" now resolves to another folder
        #expect(TrashGuard.verify(f) == .pathChanged)
        model.requestTrash([f])
        model.confirmTrash()
        #expect(trash.trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path("f.bin")))
        #expect(model.alert?.message.contains("changed since the scan") == true)
    }

    @Test(.enabled(if: getuid() != 0, "root bypasses permissions"))
    func unreadableLocationReportsTheSystemError() async throws {
        let t = TempTree("tr-unreadable")
        t.file("a/f.bin", bytes: 10)
        let trash = FakeTrash()
        let (model, root) = try await scannedModel(t, trash: trash)
        let f = try #require(root.at("a/f.bin"))
        chmod(t.path("a"), 0o600)             // no search permission
        if case .unreadable(let code) = TrashGuard.verify(f) {
            #expect(code == EACCES)
        } else {
            Issue.record("expected .unreadable, got \(TrashGuard.verify(f))")
        }
        model.requestTrash([f])
        model.confirmTrash()
        #expect(trash.trashed.isEmpty)
        #expect(model.alert?.message.contains("Permission denied") == true)
        #expect(root.at("a/f.bin") === f)
    }

    @Test func trasherFailureIsReportedAndNothingIsRemoved() async throws {
        let t = TempTree("tr-fail")
        t.file("f.bin", bytes: 10)
        let trash = FakeTrash()
        trash.error = CocoaError(.fileWriteNoPermission)
        let (model, root) = try await scannedModel(t, trash: trash)
        let f = try #require(root["f.bin"])
        model.requestTrash([f])
        model.confirmTrash()
        #expect(model.alert?.title == "Couldn't move to Trash")
        #expect(model.alert?.message.hasPrefix("f.bin:") == true)
        #expect(root["f.bin"] === f)
    }

    @Test func detachedPendingItemsAreSkipped() {
        let model = AppModel(trasher: { _ in Issue.record("must not trash") })
        let orphan = FileNode(name: "o", isDirectory: false, isSymlink: false, diskSize: 0, apparentSize: 0, mtime: 0, parent: nil)
        model.pendingTrash = [orphan]
        model.confirmTrash()
        #expect(model.pendingTrash.isEmpty)
        #expect(model.alert == nil)
        #expect(model.volume == nil)
    }

    @Test func trashedItemsLeaveSearchResultsAndSelections() async throws {
        let t = TempTree("tr-search")
        t.file("a/report.pdf", bytes: 10)
        t.file("b/report.txt", bytes: 5)
        let (model, root) = try await scannedModel(t)
        model.searchText = "report"
        await model.performSearch()
        #expect(model.searchResults.count == 2)
        model.viewMode = .list
        model.listSelection = [root["a"]!.id]
        model.requestTrash([root["a"]!])
        model.confirmTrash()
        #expect(model.searchResults.map(\.name) == ["report.txt"])
        #expect(model.listSelection.isEmpty)
    }
}

@Suite("TrashGuard")
struct TrashGuardTests {
    @Test(arguments: [
        "/", "/System", "/System/Library/CoreServices", "/Library", "/Applications", "/Users",
        "/usr", "/usr/bin/ls", "/bin/zsh", "/sbin/mount", "/private/var/db/x", "/private/etc",
        "/Library/Apple/System", "/Volumes", "/tmp", "/private/tmp", "/usr/local", "/Users/Shared",
    ])
    func systemLocationsAreProtected(path: String) {
        #expect(TrashGuard.isProtected(path))
    }

    @Test func homeAndItsStandardFoldersAreProtectedButNotTheirContents() {
        let home = NSHomeDirectory()
        for sub in ["", "/Library", "/Desktop", "/Documents", "/Downloads", "/Movies", "/Music", "/Pictures", "/Public", "/Applications"] {
            #expect(TrashGuard.isProtected(home + sub), "\(sub)")
        }
        #expect(!TrashGuard.isProtected(home + "/Downloads/installer.dmg"))
        #expect(!TrashGuard.isProtected(home + "/Library/Caches/com.example"))
        #expect(!TrashGuard.isProtected("/usr/local/Cellar/thing"))
        #expect(!TrashGuard.isProtected(TempTree("tg").root))
    }

    @Test func realPathResolvesSymlinksAndDots() {
        let t = TempTree("rp")
        t.dir("real/sub")
        t.symlink("link", to: t.path("real"))
        #expect(TrashGuard.realPath(t.path("link/sub/..")) == t.path("real"))
        #expect(TrashGuard.realPath("/tmp") == "/private/tmp")
        #expect(TrashGuard.realPath(t.path("missing")) == nil)
    }

    @Test func verifyChecksKindSizeAndTime() {
        let t = TempTree("verify")
        let file = t.file("f.bin", bytes: 123)
        let dir = t.dir("d")
        let link = t.symlink("l", to: file)
        let m = mtimeSeconds(file)

        #expect(TrashGuard.verify(path: file, isDirectory: false, isSymlink: false) == .ok)
        #expect(TrashGuard.verify(path: file, isDirectory: false, isSymlink: false, expectedMtime: m, expectedSize: 123) == .ok)
        #expect(TrashGuard.verify(path: file, isDirectory: false, isSymlink: false, expectedMtime: m + 1) == .changedKind)
        #expect(TrashGuard.verify(path: file, isDirectory: false, isSymlink: false, expectedSize: 124) == .changedKind)
        #expect(TrashGuard.verify(path: file, isDirectory: true, isSymlink: false) == .changedKind)
        #expect(TrashGuard.verify(path: dir, isDirectory: true, isSymlink: false, expectedMtime: 1, expectedSize: 1) == .ok)
        #expect(TrashGuard.verify(path: dir, isDirectory: false, isSymlink: false) == .changedKind)
        #expect(TrashGuard.verify(path: link, isDirectory: false, isSymlink: true) == .ok)
        #expect(TrashGuard.verify(path: link, isDirectory: false, isSymlink: false) == .changedKind)
        #expect(TrashGuard.verify(path: t.path("nope"), isDirectory: false, isSymlink: false) == .gone)
        #expect(TrashGuard.verify(path: t.path("nodir/nope"), isDirectory: false, isSymlink: false) == .gone)
    }

    @Test func hardLinkedFilesSkipTheSizeCheck() {
        // Extra hard links are recorded with size 0 by the scanner, so size can't be compared.
        let t = TempTree("verify-hl")
        let f = t.file("f.bin", bytes: 500)
        t.hardlink("g.bin", to: "f.bin")
        #expect(TrashGuard.verify(path: t.path("g.bin"), isDirectory: false, isSymlink: false, expectedSize: 0) == .ok)
        #expect(TrashGuard.verify(path: f, isDirectory: false, isSymlink: false, expectedSize: 0) == .ok)
    }

    @Test func verifyOfScannedNodesInNonASCIIFolders() throws {
        // Node paths come from readdir; the parent check compares them with realpath(3).
        // Both must agree on Unicode normalization or every item in such folders is refused.
        let t = TempTree("verify-unicode")
        t.file("caf\u{E9}/composed.txt", bytes: 3)          // NFC
        t.file("cafe\u{301}2/decomposed.txt", bytes: 3)     // NFD
        t.file("日本語/ファイル.txt", bytes: 3)
        t.file("emoji 🎉/x.txt", bytes: 3)
        let root = try scanTree(t.root)
        for dir in root.children {
            for f in dir.children {
                #expect(TrashGuard.verify(f) == .ok, "\(f.path)")
            }
        }
    }

    @Test func unreliableMeansOwnEntryFailed() {
        let root = makeTree(rootName: "/r", ["dir/f:1", "file:1", "bad\u{FFFD}name/x:1"])
        #expect(!TrashGuard.isUnreliable(root["file"]!))
        root["file"]!.errorCount = 1
        #expect(TrashGuard.isUnreliable(root["file"]!))
        root["dir"]!.errorCount = 3                       // errors somewhere inside a folder
        #expect(!TrashGuard.isUnreliable(root["dir"]!))
        root["bad\u{FFFD}name"]!.errorCount = 1           // lossy (non-UTF-8) folder name
        #expect(TrashGuard.isUnreliable(root["bad\u{FFFD}name"]!))
    }
}

@Suite("LaunchSafety")
struct LaunchSafetyTests {
    @Test(arguments: ["App.app", "run.command", "x.TOOL", "s.sh", "s.zsh", "a.py", "a.rb", "i.pkg",
                      "w.workflow", "a.scpt", "j.jar", "l.webloc", "p.mobileconfig", "d.dmg", "x.terminal"])
    func knownLaunchableExtensions(name: String) {
        #expect(LaunchSafety.isLaunchable(path: "/nonexistent/\(name)"))
    }

    @Test func typesThatConformToExecutableAreLaunchable() {
        #expect(LaunchSafety.isLaunchable(path: "/nonexistent/setup.exe"))   // not in the list; UTType says executable
    }

    @Test func documentsAreNotLaunchable() {
        for name in ["photo.jpg", "notes.txt", "report.pdf", "movie.mov", "archive.zip", "noext"] {
            #expect(!LaunchSafety.isLaunchable(path: "/nonexistent/\(name)"), "\(name)")
        }
    }

    @Test func executeBitMakesAFileLaunchable() {
        let t = TempTree("exec")
        #expect(LaunchSafety.isLaunchable(path: t.file("tool", bytes: 10, mode: 0o755)))
        #expect(LaunchSafety.isLaunchable(path: t.file("sneaky.txt", bytes: 10, mode: 0o744)))
        #expect(!LaunchSafety.isLaunchable(path: t.file("plain", bytes: 10, mode: 0o644)))
        let dir = t.dir("folder")   // directories have x bits but aren't launched
        #expect(!LaunchSafety.isLaunchable(path: dir))
    }
}

@Suite("Format")
struct FormatTests {
    @Test func displaySafeLeavesOrdinaryTextAlone() {
        for s in ["report.pdf", "Café Photos", "日本語", "emoji 🎉", "a b-c_d.e", ""] {
            #expect(Format.displaySafe(s) == s)
        }
    }

    @Test func displaySafeNeutralizesSpoofingAndControlCharacters() {
        let spoof = "invoice\u{202E}fdp.app"        // renders as "invoiceppa.pdf"
        let safe = Format.displaySafe(spoof)
        #expect(!safe.unicodeScalars.contains("\u{202E}"))
        #expect(safe == "invoice\u{FFFD}fdp.app")
        #expect(Format.displaySafe("a\nb\tc\u{0}") == "a\u{FFFD}b\u{FFFD}c\u{FFFD}")
        #expect(Format.displaySafe("zero\u{200B}width") == "zero\u{FFFD}width")
        #expect(Format.displaySafe("x\u{2028}y\u{2029}z") == "x\u{FFFD}y\u{FFFD}z")
        #expect(Format.displaySafe("p\u{E000}u") == "p\u{FFFD}u")            // private use
        #expect(Format.displaySafe("u\u{0378}n") == "u\u{FFFD}n")            // unassigned
    }

    @Test func numbersUseSystemFormatters() {
        #expect(Format.bytes(0) == ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
        #expect(Format.bytes(1_500_000) == ByteCountFormatter.string(fromByteCount: 1_500_000, countStyle: .file))
        #expect(Format.count(1_234_567) == 1_234_567.formatted(.number))
    }
}
