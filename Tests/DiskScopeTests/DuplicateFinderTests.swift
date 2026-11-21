import AppKit
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DiskScope

/// Writes exact bytes (parent folders created as needed).
@discardableResult
func writeFile(_ path: String, _ data: Data) -> String {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    precondition(FileManager.default.createFile(atPath: path, contents: data), "create \(path)")
    return path
}

@discardableResult
func writeFile(_ path: String, _ text: String) -> String { writeFile(path, Data(text.utf8)) }

/// Deterministic pseudo-random bytes.
func noise(_ count: Int, seed: UInt64) -> Data {
    var state = seed &+ 0x9E37_79B9_7F4A_7C15
    var out = Data(capacity: count)
    for _ in 0..<count {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        out.append(UInt8(truncatingIfNeeded: state))
    }
    return out
}

func sha256Hex(_ data: Data) -> String { DuplicateFinder.hex(SHA256.hash(data: data)) }

func findDuplicates(_ a: String, _ b: String?, _ options: DupOptions = DupOptions()) throws -> DupResult {
    try #require(try DuplicateFinder().run(folderA: a, folderB: b, options: options) { _ in })
}

@Suite("Duplicate finder")
struct DuplicateFinderTests {
    @Test func findsAFileThatExistsInBothFolders() throws {
        let t = TempTree("dup-cross")
        writeFile(t.path("A/notes.txt"), "hello world")
        writeFile(t.path("B/deep/copy of notes.txt"), "hello world")
        writeFile(t.path("B/other.txt"), "hello wxrld")          // same size, different content
        let r = try findDuplicates(t.path("A"), t.path("B"))

        #expect(r.twoFolders)
        #expect(r.folders == [t.path("A"), t.path("B")])
        #expect(r.groups.count == 1)
        let g = try #require(r.groups.first)
        #expect(g.files.map(\.path) == [t.path("A/notes.txt"), t.path("B/deep/copy of notes.txt")])
        #expect(g.files.map(\.side) == [.a, .b])
        #expect(g.size == 11)
        #expect(g.wasted == 11)
        #expect(g.digest == sha256Hex(Data("hello world".utf8)))
        #expect(g.id == "11-\(g.digest)")
        #expect(r.filesSeen == 3)
        #expect(r.totalWasted == 11)
    }

    @Test func sameSizeDifferentContentIsNotADuplicate() throws {
        let t = TempTree("dup-size")
        writeFile(t.path("A/a.bin"), noise(5000, seed: 1))
        writeFile(t.path("B/b.bin"), noise(5000, seed: 2))
        #expect(try findDuplicates(t.path("A"), t.path("B")).groups.isEmpty)
    }

    @Test func filesThatDifferOnlyAfterTheFirst64KBAreNotDuplicates() throws {
        let t = TempTree("dup-tail")
        var one = noise(200_000, seed: 7)
        writeFile(t.path("A/big.bin"), one)
        one[one.count - 1] ^= 0xFF
        writeFile(t.path("B/big.bin"), one)
        #expect(try findDuplicates(t.path("A"), t.path("B")).groups.isEmpty)
    }

    @Test func identicalLargeFilesAreHashedInFull() throws {
        let t = TempTree("dup-large")
        let data = noise(300_000, seed: 11)
        writeFile(t.path("A/movie.mov"), data)
        writeFile(t.path("B/movie copy.mov"), data)
        let g = try #require(try findDuplicates(t.path("A"), t.path("B")).groups.first)
        #expect(g.digest == sha256Hex(data))
        #expect(g.size == 300_000)
    }

    @Test func copiesInsideOneFolderNeedTheOption() throws {
        let t = TempTree("dup-same")
        writeFile(t.path("A/1.txt"), "same content")
        writeFile(t.path("A/sub/2.txt"), "same content")
        writeFile(t.path("B/unrelated.txt"), "something else")
        #expect(try findDuplicates(t.path("A"), t.path("B")).groups.isEmpty)

        var options = DupOptions()
        options.includeSameFolder = true
        let r = try findDuplicates(t.path("A"), t.path("B"), options)
        #expect(r.groups.count == 1)
        #expect(r.groups[0].files.map(\.side) == [.a, .a])
    }

    @Test func singleFolderModeFindsCopiesWithinIt() throws {
        let t = TempTree("dup-single")
        writeFile(t.path("A/x.txt"), "abc123")
        writeFile(t.path("A/y/x.txt"), "abc123")
        writeFile(t.path("A/y/z/x.txt"), "abc123")
        let r = try findDuplicates(t.path("A"), nil)
        #expect(!r.twoFolders)
        #expect(r.folders == [t.path("A")])
        let g = try #require(r.groups.first)
        #expect(g.copies == 3)
        #expect(g.wasted == 12)
        #expect(Set(g.files.map(\.side)) == [.a])
    }

    @Test func hardLinksAreNotDuplicates() throws {
        let t = TempTree("dup-hard")
        writeFile(t.path("A/original.txt"), "shared storage")
        t.hardlink("A/link.txt", to: "A/original.txt")
        writeFile(t.path("B/real copy.txt"), "shared storage")
        let r = try findDuplicates(t.path("A"), t.path("B"))
        #expect(r.hardLinks == 1)
        let g = try #require(r.groups.first)
        #expect(g.copies == 2)                 // one name for the hard-linked file + the real copy
        #expect(g.files.filter { $0.side == .a }.count == 1)
    }

    @Test func emptyFilesAreIgnored() throws {
        let t = TempTree("dup-empty")
        writeFile(t.path("A/empty"), Data())
        writeFile(t.path("B/empty"), Data())
        #expect(try findDuplicates(t.path("A"), t.path("B")).groups.isEmpty)
    }

    @Test func minimumSizeFiltersSmallFiles() throws {
        let t = TempTree("dup-min")
        writeFile(t.path("A/small"), noise(500, seed: 3))
        writeFile(t.path("B/small"), noise(500, seed: 3))
        var options = DupOptions()
        options.minSize = 1024
        #expect(try findDuplicates(t.path("A"), t.path("B"), options).groups.isEmpty)
        options.minSize = 500
        #expect(try findDuplicates(t.path("A"), t.path("B"), options).groups.count == 1)
    }

    @Test func hiddenFilesAndFoldersNeedTheOption() throws {
        let t = TempTree("dup-hidden")
        writeFile(t.path("A/.secret"), "hidden twin")
        writeFile(t.path("B/.config/visible"), "hidden twin")
        #expect(try findDuplicates(t.path("A"), t.path("B")).groups.isEmpty)
        var options = DupOptions()
        options.includeHidden = true
        #expect(try findDuplicates(t.path("A"), t.path("B"), options).groups.count == 1)
    }

    @Test func packagesAreSkippedUnlessAsked() throws {
        let t = TempTree("dup-pkg")
        writeFile(t.path("A/Thing.app/Contents/Resources/data.bin"), noise(2000, seed: 5))
        writeFile(t.path("B/data.bin"), noise(2000, seed: 5))
        #expect(try findDuplicates(t.path("A"), t.path("B")).groups.isEmpty)
        var options = DupOptions()
        options.includePackages = true
        #expect(try findDuplicates(t.path("A"), t.path("B"), options).groups.count == 1)
    }

    @Test func symlinksAreNeverFollowed() throws {
        let t = TempTree("dup-link")
        writeFile(t.path("B/real/file.txt"), "target content")
        t.dir("A")
        t.symlink("A/link-to-file.txt", to: t.path("B/real/file.txt"))
        t.symlink("A/link-to-dir", to: t.path("B/real"))
        let r = try findDuplicates(t.path("A"), t.path("B"))
        #expect(r.groups.isEmpty)
        #expect(r.filesSeen == 1)   // only the real file in B
    }

    @Test(.timeLimit(.minutes(1)))
    func fifosAreNeverOpened() throws {
        let t = TempTree("dup-fifo")
        t.dir("A"); t.dir("B")
        #expect(mkfifo(t.path("A/pipe"), 0o644) == 0)
        #expect(mkfifo(t.path("B/pipe"), 0o644) == 0)
        writeFile(t.path("A/f"), "x1")
        writeFile(t.path("B/f"), "x1")
        let r = try findDuplicates(t.path("A"), t.path("B"))
        #expect(r.groups.count == 1)
        #expect(r.groups[0].files.map(\.name) == ["f", "f"])
    }

    @Test func overlappingFoldersAreRejected() throws {
        let t = TempTree("dup-overlap")
        t.dir("A/inner")
        #expect(throws: DupError.overlapping) { try DuplicateFinder().run(folderA: t.path("A"), folderB: t.path("A/inner")) { _ in } }
        #expect(throws: DupError.overlapping) { try DuplicateFinder().run(folderA: t.path("A/inner"), folderB: t.path("A")) { _ in } }
        #expect(throws: DupError.overlapping) { try DuplicateFinder().run(folderA: t.path("A"), folderB: t.path("A")) { _ in } }
        #expect(throws: DupError.overlapping) { try DuplicateFinder().run(folderA: "/", folderB: t.path("A")) { _ in } }
        #expect(DuplicateFinder.overlaps("/x/ab", "/x/a") == false)   // prefix of the name, not a parent
    }

    @Test func aFileOrMissingPathIsNotAFolder() throws {
        let t = TempTree("dup-notdir")
        let file = writeFile(t.path("file.txt"), "x")
        #expect(throws: DupError.notAFolder(file)) { try DuplicateFinder().run(folderA: file, folderB: nil) { _ in } }
        let missing = t.path("missing")
        #expect(throws: DupError.notAFolder(missing)) { try DuplicateFinder().run(folderA: missing, folderB: nil) { _ in } }
        #expect(DupError.overlapping.errorDescription?.contains("overlap") == true)
    }

    @Test func rootsAreCanonicalized() throws {
        let t = TempTree("dup-canon")
        writeFile(t.path("A/f"), "data!")
        writeFile(t.path("B/g"), "data!")
        t.symlink("A-alias", to: t.path("A"))
        let r = try findDuplicates(t.path("A-alias"), t.path("B"))
        #expect(r.groups.first?.files.first?.path == t.path("A/f"))
    }

    @Test func cancellingReturnsNil() throws {
        let t = TempTree("dup-cancel")
        writeFile(t.path("A/f"), "x")
        let finder = DuplicateFinder()
        finder.cancel()
        #expect(finder.isCancelled)
        #expect(try finder.run(folderA: t.path("A"), folderB: nil) { _ in } == nil)
    }

    @Test func progressReachesTheHashingStage() throws {
        let t = TempTree("dup-progress")
        for i in 0..<20 {
            writeFile(t.path("A/\(i).bin"), noise(1000, seed: UInt64(i)))
            writeFile(t.path("B/\(i).bin"), noise(1000, seed: UInt64(i)))
        }
        final class Log: @unchecked Sendable { let lock = NSLock(); var items: [DupProgress] = [] }
        let log = Log()
        let r = try #require(try DuplicateFinder().run(folderA: t.path("A"), folderB: t.path("B")) { p in
            log.lock.withLock { log.items.append(p) }
        })
        #expect(r.groups.count == 20)
        let last = try #require(log.lock.withLock { log.items.last })
        #expect(last.stage == .hashing)
        #expect(last.candidates == 40)
        #expect(last.hashedFiles == 40)
        #expect(last.bytesHashed == 40_000)
        #expect(last.fraction == 1)
        #expect(DupProgress().fraction == nil)
    }

    @Test func groupsAreSortedByWastedSpace() throws {
        let t = TempTree("dup-sort")
        writeFile(t.path("A/small"), noise(100, seed: 1)); writeFile(t.path("B/small"), noise(100, seed: 1))
        writeFile(t.path("A/big"), noise(9000, seed: 2)); writeFile(t.path("B/big"), noise(9000, seed: 2))
        writeFile(t.path("A/mid"), noise(3000, seed: 3)); writeFile(t.path("B/mid"), noise(3000, seed: 3))
        #expect(try findDuplicates(t.path("A"), t.path("B")).groups.map(\.size) == [9000, 3000, 100])
    }

    @Test func digestRefusesAFileThatChangedSinceListing() throws {
        let t = TempTree("dup-digest")
        let path = writeFile(t.path("f.bin"), noise(10, seed: 9))
        var st = stat()
        #expect(lstat(path, &st) == 0)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 16)
        defer { buffer.deallocate() }
        let good = DupFile(path: path, side: .a, size: 10, mtime: 0, dev: st.st_dev, ino: UInt64(st.st_ino))
        #expect(DuplicateFinder.digest(of: good, limit: nil, buffer: buffer) == sha256Hex(noise(10, seed: 9)))
        let wrongSize = DupFile(path: path, side: .a, size: 11, mtime: 0, dev: st.st_dev, ino: UInt64(st.st_ino))
        #expect(DuplicateFinder.digest(of: wrongSize, limit: nil, buffer: buffer) == nil)
        let wrongInode = DupFile(path: path, side: .a, size: 10, mtime: 0, dev: st.st_dev, ino: UInt64(st.st_ino) + 1)
        #expect(DuplicateFinder.digest(of: wrongInode, limit: nil, buffer: buffer) == nil)
        #expect(DuplicateFinder.digest(of: good, limit: nil, buffer: buffer, isCancelled: { true }) == nil)
        t.symlink("link", to: path)
        let viaLink = DupFile(path: t.path("link"), side: .a, size: 10, mtime: 0, dev: st.st_dev, ino: UInt64(st.st_ino))
        #expect(DuplicateFinder.digest(of: viaLink, limit: nil, buffer: buffer) == nil)   // O_NOFOLLOW
    }
}

@Suite("Content preview")
struct ContentPreviewTests {
    @Test func kindsComeFromTheFileType() {
        #expect(PreviewLoader.kind(forPath: "/x/a.mov") == .media)
        #expect(PreviewLoader.kind(forPath: "/x/a.mp3") == .media)
        #expect(PreviewLoader.kind(forPath: "/x/a.pdf") == .pdf)
        #expect(PreviewLoader.kind(forPath: "/x/a.png") == .image)
        #expect(PreviewLoader.kind(forPath: "/x/a.swift") == .text)
        #expect(PreviewLoader.kind(forPath: "/x/README") == .other)
        #expect(PreviewLoader.isMedia("/x/a.mp4"))
    }

    @Test func textIsReadWithALimitAndSniffed() throws {
        let t = TempTree("pv-text")
        let plain = writeFile(t.path("notes"), "line one\nline two\n")
        #expect(PreviewLoader.readText(plain, sniff: true)?.0 == "line one\nline two\n")
        let binary = writeFile(t.path("blob"), Data([0x41, 0x00, 0x42]))
        #expect(PreviewLoader.readText(binary, sniff: true) == nil)
        #expect(PreviewLoader.readText(binary, sniff: false) != nil)
        let big = writeFile(t.path("big.txt"), String(repeating: "x", count: PreviewLoader.textLimit + 10))
        let (text, truncated) = try #require(PreviewLoader.readText(big, sniff: false))
        #expect(truncated)
        #expect(text.count == PreviewLoader.textLimit)
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("hé".data(using: .utf16LittleEndian)!)
        let wide = writeFile(t.path("wide"), utf16)
        #expect(PreviewLoader.readText(wide, sniff: true)?.0 == "hé")
    }

    @Test func safeReadRefusesSymlinksAndFifos() throws {
        let t = TempTree("pv-safe")
        let real = writeFile(t.path("real.txt"), "content")
        t.symlink("link.txt", to: real)
        #expect(PreviewLoader.readPrefix(t.path("link.txt"), limit: 100) == nil)
        #expect(mkfifo(t.path("pipe"), 0o644) == 0)
        #expect(PreviewLoader.readPrefix(t.path("pipe"), limit: 100) == nil)   // returns immediately
        #expect(PreviewLoader.readPrefix(real, limit: 3) == Data("con".utf8))
    }

    @Test func imagesAreDownsampled() throws {
        let t = TempTree("pv-image")
        let path = t.path("pic.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 1000, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        writeFile(path, rep.representation(using: .png, properties: [:])!)
        let (image, pixels) = try #require(PreviewLoader.image(at: path))
        #expect(pixels == CGSize(width: 3000, height: 1000))
        #expect(max(image.size.width, image.size.height) <= CGFloat(PreviewLoader.imageMaxPixels))
        #expect(PreviewLoader.image(at: writeFile(t.path("fake.png"), "not an image")) == nil)
    }
}
