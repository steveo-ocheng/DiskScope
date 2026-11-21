import Foundation
import Darwin
import Testing
@testable import DiskScope

/// Independent reference walk using lstat + FileManager (no symlink following).
private func referenceTotals(_ path: String) -> (disk: Int64, apparent: Int64, items: Int) {
    var disk = diskBytes(path), apparent = apparentBytes(path), items = 0
    var seen = Set<[UInt64]>()
    var stack = [path]
    while let dir = stack.popLast() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            let p = dir + "/" + name
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }
            items += 1
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            if !isDir && st.st_nlink > 1 && !seen.insert([UInt64(st.st_dev), UInt64(st.st_ino)]).inserted { continue }
            disk += Int64(st.st_blocks) * 512
            apparent += Int64(st.st_size)
            if isDir { stack.append(p) }
        }
    }
    return (disk, apparent, items)
}

private func sampleTree() -> TempTree {
    let t = TempTree("scan")
    t.file("empty.txt")
    t.file("one.bin", bytes: 1)
    t.file("a/f1.bin", bytes: 5_000)
    t.file("a/b/f2.bin", bytes: 100_000)
    t.file("a/b/c/f3.bin", bytes: 12_345)
    t.dir("a/emptydir")
    for i in 0..<40 { t.file("many/file\(i).dat", bytes: i * 100) }
    t.file("café/naïve.txt", bytes: 10)   // non-ASCII names
    return t
}

/// Map of relative path → (disk, apparent, items, errors) for structural comparisons.
private func signature(_ root: FileNode) -> [String: [Int64]] {
    var out: [String: [Int64]] = [:]
    for n in root.allNodes {
        out[String(n.path.dropFirst(root.path.count))] =
            [n.diskSize, n.apparentSize, Int64(n.itemCount), Int64(n.errorCount), n.isDirectory ? 1 : 0]
    }
    return out
}

@Suite("Scanner")
struct ScannerTests {
    @Test func totalsMatchIndependentLstatWalk() throws {
        let t = sampleTree()
        let root = try scanTree(t.root)
        let ref = referenceTotals(t.root)
        #expect(root.diskSize == ref.disk)
        #expect(root.apparentSize == ref.apparent)
        #expect(root.itemCount == ref.items)
        #expect(root.errorCount == 0)
        #expect(root.name == t.root)
        #expect(root.isDirectory && !root.isSymlink && root.parent == nil)
    }

    @Test func perItemSizesAndMtimesMatchLstat() throws {
        let t = sampleTree()
        let root = try scanTree(t.root)
        for rel in ["one.bin", "a/f1.bin", "a/b/f2.bin", "a/b/c/f3.bin", "empty.txt", "café/naïve.txt"] {
            let node = try #require(root.at(rel), "missing \(rel)")
            #expect(node.diskSize == diskBytes(t.path(rel)), "\(rel)")
            #expect(node.apparentSize == apparentBytes(t.path(rel)), "\(rel)")
            #expect(Int(node.modified.timeIntervalSince1970) == mtimeSeconds(t.path(rel)), "\(rel)")
            #expect(node.path == t.path(rel))
        }
        #expect(root.at("a/emptydir")?.isDirectory == true)
        #expect(root.at("a/emptydir")?.children.isEmpty == true)
        #expect(root["many"]?.children.count == 40)
        #expect(root["a"]?.itemCount == 6)   // f1, b, f2, c, f3, emptydir
    }

    @Test(arguments: [1, 2, 8, 16])
    func threadCountDoesNotChangeResults(threads: Int) throws {
        let t = sampleTree()
        let single = try scanTree(t.root, threads: 1)
        let multi = try scanTree(t.root, threads: threads)
        #expect(signature(single) == signature(multi))
    }

    @Test func zeroThreadsStillScans() throws {
        let t = sampleTree()
        let root = try scanTree(t.root, threads: 0)   // clamped to 1
        #expect(root.itemCount == referenceTotals(t.root).items)
    }

    @Test func hardLinksAreCountedOnce() throws {
        let t = TempTree("hl")
        t.file("orig.bin", bytes: 50_000)
        t.hardlink("link.bin", to: "orig.bin")
        t.hardlink("sub/link2.bin", to: "orig.bin")
        let root = try scanTree(t.root)
        let sizes = ["orig.bin", "link.bin", "sub/link2.bin"].map { root.at($0)!.apparentSize }
        #expect(sizes.filter { $0 == 50_000 }.count == 1)
        #expect(sizes.filter { $0 == 0 }.count == 2)
        #expect(root.itemCount == 4)
        #expect(root.diskSize == referenceTotals(t.root).disk)
    }

    @Test func symlinksAreLeavesAndNeverFollowed() throws {
        let t = TempTree("sl")
        let outside = TempTree("outside")
        outside.file("huge.bin", bytes: 300_000)
        t.file("real.txt", bytes: 10)
        t.symlink("to-outside", to: outside.root)
        t.symlink("to-etc", to: "/etc")
        t.symlink("loop", to: ".")
        t.symlink("dangling", to: t.path("nope"))
        let root = try scanTree(t.root)
        for name in ["to-outside", "to-etc", "loop", "dangling"] {
            let n = try #require(root[name])
            #expect(n.isSymlink, "\(name)")
            #expect(!n.isDirectory, "\(name)")
            #expect(n.children.isEmpty, "\(name)")
            #expect(n.errorCount == 0)
        }
        #expect(root.apparentSize < 300_000)   // outside tree not counted
        #expect(root.itemCount == 5)
    }

    @Test func symlinkedRootIsFollowed() throws {
        let t = sampleTree()
        let holder = TempTree("holder")
        let link = holder.symlink("link", to: t.root)
        let root = try scanTree(link)
        #expect(root.name == link)
        #expect(root.itemCount == referenceTotals(t.root).items)
    }

    @Test func trailingSlashRootProducesCleanPaths() throws {
        let t = sampleTree()
        let root = try scanTree(t.root + "/")
        #expect(root.at("a/f1.bin")?.apparentSize == 5_000)
        #expect(root.at("a/b/f2.bin")?.path == t.root + "/a/b/f2.bin")
    }

    @Test(.enabled(if: getuid() != 0, "root bypasses permissions"))
    func unreadableDirectoryIsFlagged() throws {
        let t = TempTree("perm")
        t.file("locked/secret.bin", bytes: 1_000)
        t.file("ok.txt", bytes: 3)
        chmod(t.path("locked"), 0o000)
        let root = try scanTree(t.root)
        let locked = try #require(root["locked"])
        #expect(locked.errorCount == 1)
        #expect(locked.children.isEmpty)
        #expect(root.errorCount == 1)
        #expect(root["ok.txt"]?.errorCount == 0)
        #expect(!TrashGuard.isUnreliable(locked))   // a folder with errors can still be trashed
    }

    @Test(.enabled(if: getuid() != 0, "root bypasses permissions"))
    func entriesThatCannotBeStatedAreFlaggedLeaves() throws {
        let t = TempTree("nostat")
        t.file("rdonly/a.bin", bytes: 100)
        t.dir("rdonly/sub")
        chmod(t.path("rdonly"), 0o444)   // can list names, can't stat entries
        let root = try scanTree(t.root)
        let dir = try #require(root["rdonly"])
        #expect(dir.children.count == 2)
        for child in dir.children {
            #expect(child.errorCount == 1)
            #expect(!child.isDirectory)   // unknown type → leaf, never descended
            #expect(child.diskSize == 0 && child.modified == .distantPast)
            #expect(TrashGuard.isUnreliable(child))
        }
        #expect(dir.errorCount == 2)
        #expect(root.errorCount == 2)
    }

    @Test func pathsLongerThanPathMaxAreScanned() throws {
        let t = TempTree("deep")
        let component = String(repeating: "d", count: 200)
        let depth = 8   // 8 × 201 bytes > PATH_MAX (1024)
        var fd = open(t.root, O_RDONLY | O_DIRECTORY)
        for _ in 0..<depth {
            #expect(mkdirat(fd, component, 0o755) == 0)
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY)
            close(fd)
            fd = next
        }
        let file = openat(fd, "bottom.bin", O_CREAT | O_WRONLY, 0o644)
        let bytes = [UInt8](repeating: 7, count: 4_321)
        _ = bytes.withUnsafeBytes { write(file, $0.baseAddress, $0.count) }
        close(file)
        close(fd)

        let root = try scanTree(t.root)
        #expect(root.errorCount == 0)
        #expect(root.itemCount == depth + 1)
        var n = root
        for _ in 0..<depth { n = try #require(n[component]) }
        let bottom = try #require(n["bottom.bin"])
        #expect(bottom.apparentSize == 4_321)
        #expect(bottom.path.utf8.count > Int(PATH_MAX))
    }

    @Test func progressIsReportedWithFinalTotals() throws {
        let t = sampleTree()
        final class Box: @unchecked Sendable { let lock = NSLock(); var reports: [ScanStats] = [] }
        let box = Box()
        let root = try Scanner().scan(path: t.root, stayOnDevice: false) { s in
            box.lock.withLock { box.reports.append(s) }
        }!
        let last = try #require(box.lock.withLock { box.reports.last })
        #expect(last.items == root.itemCount)
        #expect(last.errors == 0)
        #expect(last.bytes == root.diskSize - diskBytes(t.root))   // root's own size isn't an "item"
        #expect(!last.currentPath.isEmpty)
    }

    @Test func hugeDirectoriesAreReadCompletely() throws {
        // Directories with >4096 entries take the periodic progress/cancellation path mid-listing.
        let t = TempTree("huge")
        let dir = t.dir("big")
        for i in 0..<5_000 { close(open(dir + "/f\(i)", O_CREAT | O_WRONLY, 0o644)) }
        final class Box: @unchecked Sendable { let lock = NSLock(); var count = 0 }
        let box = Box()
        let root = try #require(try Scanner().scan(path: t.root, stayOnDevice: false, threads: 2) { _ in
            box.lock.withLock { box.count += 1 }
        })
        #expect(root["big"]?.children.count == 5_000)
        #expect(root.itemCount == 5_001)
        #expect(box.count >= 1)
    }

    @Test func cancelledBeforeStartReturnsNil() throws {
        let t = sampleTree()
        let scanner = Scanner()
        scanner.cancel()
        #expect(scanner.isCancelled)
        let result = try scanner.scan(path: t.root, stayOnDevice: false) { _ in }
        #expect(result == nil)
    }

    @Test func cancellingALargeScanReturnsNilPromptly() throws {
        // Whole-disk scan, cancelled almost immediately: exercises abort, the "/" device logic
        // (stayOnDevice on the boot volume) and the /Volumes, /dev skip list.
        // Timed from the cancel() call: on a busy CI machine the timer itself can fire late.
        final class CancelTime: @unchecked Sendable {
            private let lock = NSLock(); private var value: Date?
            var date: Date? { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
        }
        let scanner = Scanner()
        let cancelledAt = CancelTime()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(150)) {
            cancelledAt.date = Date()
            scanner.cancel()
        }
        let result = try scanner.scan(path: "/", stayOnDevice: true) { _ in }
        #expect(result == nil)
        let waited = Date().timeIntervalSince(try #require(cancelledAt.date))
        #expect(waited < 5, "scan took \(waited) s to stop after cancel()")
    }

    @Test func skipListCoversDuplicatesAndOtherDisks() {
        #expect(Scanner.skipPaths == ["/System/Volumes/Data", "/Volumes", "/dev",
                                      "/System/Volumes/Update/mnt1", "/System/Volumes/Update/SFR/mnt1"])
        #expect((4...12).contains(Scanner.defaultThreadCount))
    }

    @Test func missingRootThrowsENOENT() {
        let t = TempTree("missing")
        let error = #expect(throws: ScanError.self) {
            _ = try Scanner().scan(path: t.path("nope"), stayOnDevice: false) { _ in }
        }
        guard case let .cannotOpen(path, code)? = error else { Issue.record("wrong error"); return }
        #expect(code == ENOENT)
        #expect(path.hasSuffix("/nope"))
    }

    @Test func fileRootThrowsENOTDIR() {
        let t = TempTree("fileroot")
        let f = t.file("x.txt", bytes: 1)
        let error = #expect(throws: ScanError.self) {
            _ = try Scanner().scan(path: f, stayOnDevice: false) { _ in }
        }
        guard case let .cannotOpen(_, code)? = error else { Issue.record("wrong error"); return }
        #expect(code == ENOTDIR)
    }

    @Test(.enabled(if: getuid() != 0, "root bypasses permissions"))
    func unreadableRootThrowsWithFullDiskAccessHint() {
        let t = TempTree("lockedroot")
        let locked = t.dir("locked")
        chmod(locked, 0o000)
        do {
            _ = try Scanner().scan(path: locked, stayOnDevice: false) { _ in }
            Issue.record("expected an error")
        } catch let error as ScanError {
            guard case let .cannotOpen(_, code) = error else { return }
            #expect(code == EACCES)
            #expect(error.localizedDescription.contains("Full Disk Access"))
            #expect(error.localizedDescription.contains(locked))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func otherErrorsHaveNoFullDiskAccessHint() {
        let e = ScanError.cannotOpen(path: "/x", code: ENOENT)
        #expect(e.errorDescription?.contains("No such file") == true)
        #expect(e.errorDescription?.contains("Full Disk Access") == false)
        let perm = ScanError.cannotOpen(path: "/x", code: EPERM)
        #expect(perm.errorDescription?.contains("Full Disk Access") == true)
    }

    /// Mounts a small disk image inside the scanned tree to check `stayOnDevice`.
    @Test func stayOnDeviceDoesNotDescendIntoOtherVolumes() throws {
        let t = TempTree("xdev")
        let img = t.path("img.dmg")
        let mnt = t.dir("tree/mnt")
        t.file("tree/local.bin", bytes: 2_000)
        guard run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "4m", "-fs", "HFS+", "-volname", "DSTest", img]) == 0,
              run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mnt, img]) == 0 else {
            Issue.record("hdiutil unavailable; skipping")
            return
        }
        defer { run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mnt]) }
        FileManager.default.createFile(atPath: mnt + "/inside.bin", contents: Data(count: 30_000))

        let crossing = try scanTree(t.path("tree"), stayOnDevice: false)
        #expect(crossing["mnt"]?.children.contains { $0.name == "inside.bin" } == true)

        let staying = try scanTree(t.path("tree"), stayOnDevice: true)
        let mntNode = try #require(staying["mnt"])
        #expect(mntNode.isDirectory)
        #expect(mntNode.children.isEmpty)   // other volume: listed but not entered
        #expect(staying["local.bin"]?.apparentSize == 2_000)
        #expect(staying.errorCount == 0)

        // A -nobrowse volume is hidden from the disk list…
        #expect(Volume(url: URL(fileURLWithPath: mnt)) == nil)
        // …and a mount point is never trashable, even outside the system locations.
        #expect(TrashGuard.isProtected(mnt))
        #expect(!TrashGuard.isProtected(mnt + "/inside.bin"))
    }

    @Test func invalidUTF8NamesCannotBeCreatedOnAPFS() {
        // The scanner flags names that aren't valid UTF-8, but APFS/HFS+ refuse to create them
        // (EILSEQ), so that branch can't be exercised on this machine. Document the precondition.
        let t = TempTree("utf8")
        let bytes: [CChar] = Array(t.root.utf8CString.dropLast()) + [0x2F, 0x66, -1, 0x67, 0]
        let fd = open(bytes, O_CREAT | O_WRONLY, 0o644)
        if fd >= 0 {
            close(fd)
            // If a filesystem ever accepts it, the scanner must flag it and keep a lossy name.
            let root = try? scanTree(t.root)
            let node = root?.children.first
            #expect(node?.errorCount == 1)
            #expect(node.map(TrashGuard.isUnreliable) == true)
        } else {
            #expect(errno == EILSEQ)
        }
    }
}
