import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Which of the two chosen folders a file came from.
enum DupSide: Int, Sendable, Comparable {
    case a, b
    static func < (l: DupSide, r: DupSide) -> Bool { l.rawValue < r.rawValue }
    var label: String { self == .a ? "A" : "B" }
}

/// A regular file considered by the duplicate finder. Paths are canonical (realpath'd roots).
struct DupFile: Identifiable, Hashable, Sendable {
    let path: String
    let side: DupSide
    let size: Int64
    let mtime: Int
    let dev: Int32
    let ino: UInt64

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var modified: Date { Date(timeIntervalSince1970: TimeInterval(mtime)) }
}

/// Files with identical contents (same size and SHA-256).
struct DupGroup: Identifiable, Sendable, Equatable {
    let id: String          // "<size>-<hex digest>"
    let digest: String      // hex SHA-256 of the whole file
    let size: Int64
    var files: [DupFile]

    var copies: Int { files.count }
    /// Space freed by keeping just one copy.
    var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }
    func files(on side: DupSide) -> [DupFile] { files.filter { $0.side == side } }
}

struct DupOptions: Sendable, Equatable {
    /// Files smaller than this are ignored (empty files always are).
    var minSize: Int64 = 1
    var includeHidden = false
    /// Look inside packages (apps, Photos libraries, bundles), which Finder shows as single files.
    var includePackages = false
    /// Two-folder mode: also report sets whose copies are all inside one of the folders.
    var includeSameFolder = false
}

struct DupProgress: Sendable, Equatable {
    enum Stage: Sendable { case listing, hashing }
    var stage: Stage = .listing
    var filesSeen = 0
    var candidates = 0        // files sharing a size with another file
    var hashedFiles = 0
    var bytesToHash: Int64 = 0
    var bytesHashed: Int64 = 0
    var currentPath = ""

    var fraction: Double? {
        guard stage == .hashing, bytesToHash > 0 else { return nil }
        return min(Double(bytesHashed) / Double(bytesToHash), 1)
    }
}

struct DupResult: Sendable {
    var groups: [DupGroup]
    var filesSeen = 0
    var skippedCloud = 0        // iCloud / File Provider placeholders: reading would download them
    var skippedUnreadable = 0
    var hardLinks = 0           // extra names for one file: same storage, so not duplicates
    var twoFolders = false
    var folders: [String] = []  // canonical paths of the folders searched (A, then B)

    var totalWasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }
}

enum DupError: LocalizedError, Equatable {
    case notAFolder(String)
    case overlapping

    var errorDescription: String? {
        switch self {
        case .notAFolder(let path):
            return "“\(Format.displaySafe(path))” is not a folder or no longer exists."
        case .overlapping:
            return "The folders overlap: choose two separate folders, or leave the second empty to search within one."
        }
    }
}

/// Finds files with identical contents in one folder, or between two folders.
///
/// Files are listed with readdir + fstatat (never following symlinks, like Scanner), grouped by
/// size, then by a SHA-256 of their first 64 KB, and only the files still matching are hashed
/// in full. Only regular files are ever opened, and cloud placeholders are never read.
final class DuplicateFinder: @unchecked Sendable {   // mutable state is guarded by `lock`
    static let headBytes = 64 * 1024
    /// SF_DATALESS: the contents live in the cloud; reading the file would download it.
    static let datalessFlag: UInt32 = 0x4000_0000

    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    private struct FileKey: Hashable { let dev: Int32; let ino: UInt64 }

    private struct Listing {
        var files: [DupFile] = []
        var seenInodes: Set<FileKey> = []
        var filesSeen = 0
        var cloud = 0
        var unreadable = 0
        var hardLinks = 0
    }

    /// Returns nil if cancelled. Throws if a folder can't be used.
    func run(folderA: String, folderB: String?, options: DupOptions = DupOptions(),
             progress: @escaping @Sendable (DupProgress) -> Void) throws -> DupResult? {
        let a = try Self.canonicalFolder(folderA)
        let b = try folderB.map(Self.canonicalFolder)
        if let b, Self.overlaps(a, b) { throw DupError.overlapping }
        let twoFolders = b != nil

        var p = DupProgress()
        let reporter = Reporter(progress)
        var listing = Listing()
        list(a, side: .a, options: options, into: &listing, progress: &p, reporter: reporter)
        if let b { list(b, side: .b, options: options, into: &listing, progress: &p, reporter: reporter) }
        if isCancelled { return nil }

        func qualifies(_ files: [DupFile]) -> Bool {
            guard files.count >= 2 else { return false }
            if !twoFolders || options.includeSameFolder { return true }
            return files.contains { $0.side == .a } && files.contains { $0.side == .b }
        }

        // 1. Same size.
        let bySize = Dictionary(grouping: listing.files, by: \.size).values.filter(qualifies)
        let candidates = bySize.flatMap { $0 }
        p.stage = .hashing
        p.candidates = candidates.count
        p.currentPath = ""
        // Upper bound until we know which files need a full read; it only shrinks later.
        p.bytesToHash = candidates.reduce(0) { $0 + $1.size }
        reporter.send(p, force: true)

        // 2. Same first 64 KB.
        guard let heads = digests(of: candidates, limit: Self.headBytes, progress: &p, reporter: reporter)
        else { return nil }
        var unreadable = listing.unreadable + (candidates.count - heads.count)
        let byHead = Dictionary(grouping: candidates.filter { heads[$0.path] != nil },
                                by: { "\($0.size)-\(heads[$0.path]!)" }).values.filter(qualifies)

        // 3. Same full contents (files up to 64 KB were already read completely).
        let needFull = byHead.flatMap { $0 }.filter { $0.size > Int64(Self.headBytes) }
        let headTotal = candidates.reduce(Int64(0)) { $0 + min($1.size, Int64(Self.headBytes)) }
        p.bytesToHash = headTotal + needFull.reduce(0) { $0 + $1.size }
        reporter.send(p, force: true)
        guard let fulls = digests(of: needFull, limit: nil, progress: &p, reporter: reporter) else { return nil }
        unreadable += needFull.count - fulls.count

        var final: [String: [DupFile]] = [:]
        for group in byHead {
            for f in group {
                let digest = f.size > Int64(Self.headBytes) ? fulls[f.path] : heads[f.path]
                guard let digest else { continue }
                final["\(f.size)-\(digest)", default: []].append(f)
            }
        }
        let groups = final.compactMap { key, files -> DupGroup? in
            guard qualifies(files) else { return nil }
            let sorted = files.sorted {
                $0.side != $1.side ? $0.side < $1.side : $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            let digest = String(key.split(separator: "-", maxSplits: 1)[1])
            return DupGroup(id: key, digest: digest, size: sorted[0].size, files: sorted)
        }
        .sorted { ($0.wasted, $0.size, $1.id) > ($1.wasted, $1.size, $0.id) }

        if isCancelled { return nil }
        return DupResult(groups: groups, filesSeen: listing.filesSeen, skippedCloud: listing.cloud,
                         skippedUnreadable: unreadable, hardLinks: listing.hardLinks, twoFolders: twoFolders,
                         folders: [a] + (b.map { [$0] } ?? []))
    }

    // MARK: Folders

    static func canonicalFolder(_ raw: String) throws -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard let path = TrashGuard.realPath(expanded),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw DupError.notAFolder(raw)
        }
        return path
    }

    /// Equal, nested, or either is "/" (which contains everything).
    static func overlaps(_ a: String, _ b: String) -> Bool {
        if a == "/" || b == "/" || a == b { return true }
        return a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    // MARK: Listing

    private static let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name)!

    private func list(_ root: String, side: DupSide, options: DupOptions, into out: inout Listing,
                      progress p: inout DupProgress, reporter: Reporter) {
        var packageCache: [String: Bool] = [:]
        func isPackage(_ name: String) -> Bool {
            let ext = (name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty else { return false }
            if let known = packageCache[ext] { return known }
            // The plain initializer only looks at types conforming to public.data, which packages
            // don't; ask for directory types instead and ignore made-up (dynamic) ones.
            let result = UTType(filenameExtension: ext, conformingTo: .directory)
                .map { !$0.isDynamic && $0.conforms(to: .package) } ?? false
            packageCache[ext] = result
            return result
        }
        let minSize = max(options.minSize, 1)
        var stack: [(path: String, expected: FileKey?)] = [(root, nil)]

        while let (dirPath, expected) = stack.popLast() {
            if isCancelled { return }
            let fd = open(dirPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { out.unreadable += 1; continue }
            var opened = stat()
            if let expected {
                // The folder must still be the one we listed (not swapped for something else).
                guard fstat(fd, &opened) == 0, opened.st_dev == expected.dev, UInt64(opened.st_ino) == expected.ino else {
                    close(fd); out.unreadable += 1; continue
                }
            }
            guard let dir = fdopendir(fd) else { close(fd); out.unreadable += 1; continue }
            defer { closedir(dir) }
            let prefix = dirPath == "/" ? "/" : dirPath + "/"
            var st = stat()
            var seen = 0

            while true {
                errno = 0
                guard let ent = readdir(dir) else {
                    if errno != 0 { out.unreadable += 1 }
                    break
                }
                let namePtr = (UnsafeRawPointer(ent) + Self.nameOffset).assumingMemoryBound(to: CChar.self)
                let nameLength = Int(ent.pointee.d_namlen)
                if namePtr[0] == 0x2E && (nameLength == 1 || (nameLength == 2 && namePtr[1] == 0x2E)) { continue }
                seen += 1
                if seen & 1023 == 0 && isCancelled { return }
                // A name that isn't valid UTF-8 can't be turned into an exact path: never use it.
                guard let name = String(validatingCString: namePtr) else { out.unreadable += 1; continue }
                if !options.includeHidden && name.hasPrefix(".") { continue }
                guard fstatat(dirfd(dir), namePtr, &st, AT_SYMLINK_NOFOLLOW) == 0 else { out.unreadable += 1; continue }

                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    let child = prefix + name
                    if Scanner.skipPaths.contains(child) { continue }
                    if !options.includePackages && isPackage(name) { continue }
                    stack.append((child, FileKey(dev: st.st_dev, ino: UInt64(st.st_ino))))
                case S_IFREG:
                    out.filesSeen += 1
                    let size = Int64(st.st_size)
                    guard size >= minSize else { continue }
                    if st.st_flags & Self.datalessFlag != 0 { out.cloud += 1; continue }
                    let key = FileKey(dev: st.st_dev, ino: UInt64(st.st_ino))
                    if st.st_nlink > 1, !out.seenInodes.insert(key).inserted { out.hardLinks += 1; continue }
                    out.files.append(DupFile(path: prefix + name, side: side, size: size,
                                             mtime: Int(st.st_mtimespec.tv_sec), dev: key.dev, ino: key.ino))
                default:
                    continue   // symlinks, FIFOs, sockets, devices are never opened
                }
            }
            p.filesSeen = out.filesSeen
            p.currentPath = dirPath
            reporter.send(p)
        }
    }

    // MARK: Hashing

    /// Hex SHA-256 of each file's first `limit` bytes (nil = whole file), in parallel.
    /// Files that can't be read (or changed since listing) are missing from the result. nil if cancelled.
    private func digests(of files: [DupFile], limit: Int?, progress p: inout DupProgress,
                         reporter: Reporter) -> [String: String]? {
        guard !files.isEmpty else { return [:] }
        final class Shared: @unchecked Sendable {   // guarded by `lock`
            let lock = NSLock()
            var next = 0
            var results: [String: String] = [:]
            var progress: DupProgress
            init(_ p: DupProgress) { progress = p }
        }
        let shared = Shared(p)
        let workers = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount), files.count)

        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
            defer { buffer.deallocate() }
            while true {
                let i: Int = shared.lock.withLock { defer { shared.next += 1 }; return shared.next }
                guard i < files.count, !isCancelled else { return }
                let file = files[i]
                let digest = Self.digest(of: file, limit: limit, buffer: buffer, isCancelled: { self.isCancelled }) { n in
                    shared.lock.withLock { shared.progress.bytesHashed += Int64(n) }
                }
                let snapshot: DupProgress = shared.lock.withLock {
                    if let digest { shared.results[file.path] = digest }
                    shared.progress.hashedFiles += 1
                    shared.progress.currentPath = file.path
                    return shared.progress
                }
                reporter.send(snapshot)
            }
        }
        p = shared.progress
        reporter.send(p, force: true)
        return isCancelled ? nil : shared.results
    }

    /// Reads a file that was listed as `file`. Refuses anything that's no longer that same regular file.
    static func digest(of file: DupFile, limit: Int?, buffer: UnsafeMutableRawBufferPointer,
                       isCancelled: () -> Bool = { false }, onRead: (Int) -> Void = { _ in }) -> String? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_dev == file.dev, UInt64(st.st_ino) == file.ino, Int64(st.st_size) == file.size,
              st.st_flags & datalessFlag == 0 else { return nil }
        _ = fcntl(fd, F_NOCACHE, 1)   // a one-off read shouldn't evict the user's cached files
        var hasher = SHA256()
        var remaining = limit.map { Int64($0) } ?? Int64.max
        while remaining > 0 {
            if isCancelled() { return nil }
            let want = Int(min(Int64(buffer.count), remaining))
            let n = read(fd, buffer.baseAddress, want)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
            remaining -= Int64(n)
            onRead(n)
        }
        return hex(hasher.finalize())
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        let chars = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in digest {
            out.append(chars[Int(byte >> 4)])
            out.append(chars[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Rate-limits progress callbacks to about 10 a second.
    private final class Reporter: @unchecked Sendable {   // guarded by `lock`
        private let lock = NSLock()
        private var last: UInt64 = 0
        private let callback: @Sendable (DupProgress) -> Void
        init(_ callback: @escaping @Sendable (DupProgress) -> Void) { self.callback = callback }

        func send(_ p: DupProgress, force: Bool = false) {
            let now = DispatchTime.now().uptimeNanoseconds
            let due: Bool = lock.withLock {
                guard force || now &- last >= 100_000_000 else { return false }
                last = now
                return true
            }
            if due { callback(p) }
        }
    }
}
