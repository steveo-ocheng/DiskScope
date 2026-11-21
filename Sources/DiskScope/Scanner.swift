import Foundation
import Darwin

struct ScanStats: Sendable {
    var items = 0
    var bytes: Int64 = 0
    var errors = 0
    var currentPath = ""
}

enum ScanError: LocalizedError {
    case cannotOpen(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case let .cannotOpen(path, code):
            var message = "Couldn’t scan “\(path)”: \(String(cString: strerror(code)))."
            if code == EPERM || code == EACCES {
                message += " Grant DiskScope Full Disk Access in System Settings › Privacy & Security › Full Disk Access."
            }
            return message
        }
    }
}

/// Multi-threaded directory walker (in the spirit of ncdu 2 / dust).
///
/// Worker threads pull directories off a shared LIFO stack; each directory is read with
/// readdir + fstatat(AT_SYMLINK_NOFOLLOW) relative to its own fd, so symlinks are never
/// followed. Only the thread that processes a directory touches that directory's
/// `children`, and directories are handed between threads through the queue's lock, so
/// there is no shared mutable tree state. Directory totals are filled in afterwards by a
/// single iterative pass (`FileNode.aggregateTotals`).
final class Scanner: @unchecked Sendable {   // mutable state is guarded by `cancelLock`
    private let cancelLock = NSLock()
    private var cancelled = false

    func cancel() { cancelLock.withLock { cancelled = true } }
    var isCancelled: Bool { cancelLock.withLock { cancelled } }

    /// Paths never descended into when they're below the scan root:
    /// the Data volume is already visible through firmlinks (/Users, /Applications…),
    /// /Volumes holds other disks, /dev is not real storage.
    static let skipPaths: Set<String> = ["/System/Volumes/Data", "/Volumes", "/dev"]

    /// Metadata reads are latency-bound, so a few more threads than performance cores
    /// helps; beyond ~12 contention in the filesystem layer eats the gains.
    static var defaultThreadCount: Int { min(max(ProcessInfo.processInfo.activeProcessorCount, 4), 12) }

    /// Scans `path`. Returns nil only if cancelled; throws if the root itself can't be read.
    func scan(path: String, stayOnDevice: Bool, threads: Int = Scanner.defaultThreadCount,
              progress: @escaping @Sendable (ScanStats) -> Void) throws -> FileNode? {
        // The root is something the user picked explicitly, so follow it if it's a symlink.
        var st = stat()
        guard stat(path, &st) == 0 else { throw ScanError.cannotOpen(path: path, code: errno) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw ScanError.cannotOpen(path: path, code: ENOTDIR) }
        let probe = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard probe >= 0 else { throw ScanError.cannotOpen(path: path, code: errno) }
        close(probe)

        let root = FileNode(name: path, isDirectory: true, isSymlink: false,
                            diskSize: Int64(st.st_blocks) * 512, apparentSize: Int64(st.st_size),
                            mtime: Int(st.st_mtimespec.tv_sec), parent: nil)

        var allowedDevices: Set<dev_t>?
        if stayOnDevice {
            var devices: Set<dev_t> = [st.st_dev]
            // On the boot volume, /Users, /Applications, … are firmlinks into the Data
            // volume (a different st_dev); "one filesystem" should still include them.
            if let real = realpath(path, nil) {
                defer { free(real) }
                if strcmp(real, "/") == 0 {
                    var data = stat()
                    if lstat("/System/Volumes/Data", &data) == 0 { devices.insert(data.st_dev) }
                }
            }
            allowedDevices = devices
        }

        let walk = Walk(scanner: self, allowedDevices: allowedDevices)
        walk.queue.push(Job(node: root, path: path, followSymlink: true))

        let group = DispatchGroup()
        for _ in 0..<max(threads, 1) {
            group.enter()
            let thread = Thread {
                walk.work()
                group.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.name = "DiskScope.scan"
            thread.start()
        }

        // This thread just reports progress (~10 Hz) and watches for cancellation.
        while group.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            if isCancelled { walk.queue.abort() } else { progress(walk.snapshot()) }
        }
        if isCancelled { return nil }

        progress(walk.snapshot())
        FileNode.aggregateTotals(from: root)
        return root
    }
}

// MARK: - Internals

/// Identity of a file system object, used to detect a directory being swapped between
/// the moment it's listed in its parent and the moment it's opened.
private struct FileID: Hashable { let dev: dev_t; let ino: ino_t }

private struct Job: @unchecked Sendable {   // FileNode is handed off through WorkQueue's lock
    let node: FileNode
    let path: String
    let followSymlink: Bool
    var expected: FileID? = nil  // nil for the root
}

/// LIFO work stack with completion detection: `pending` counts jobs queued + in flight.
private final class WorkQueue: @unchecked Sendable {   // all state guarded by `cond`
    private let cond = NSCondition()
    private var stack: [Job] = []
    private var pending = 0
    private var finished = false

    func push(_ job: Job) {
        cond.withLock {
            stack.append(job)
            pending += 1
            cond.signal()
        }
    }

    /// Blocks until a job is available; nil once all work is done or the walk was aborted.
    func pop() -> Job? {
        cond.withLock {
            while stack.isEmpty && !finished { cond.wait() }
            return stack.popLast()
        }
    }

    /// Marks one job done and enqueues the subdirectories it found, atomically,
    /// so `pending` can't hit zero while work is still being discovered.
    func complete(adding jobs: [Job]) {
        cond.withLock {
            if finished { return }
            stack.append(contentsOf: jobs)
            pending += jobs.count - 1
            if pending == 0 {
                finished = true
                cond.broadcast()
            } else if jobs.count == 1 {
                cond.signal()
            } else if jobs.count > 1 {
                cond.broadcast()
            }
        }
    }

    func abort() {
        cond.withLock {
            finished = true
            stack.removeAll()
            cond.broadcast()
        }
    }
}

private final class Walk: @unchecked Sendable {   // mutable state guarded by statsLock / linkLock
    private struct InodeKey: Hashable { let dev: dev_t; let ino: ino_t }
    private struct Counters { var items = 0; var bytes: Int64 = 0; var errors = 0 }

    let queue = WorkQueue()
    private let scanner: Scanner
    private let allowedDevices: Set<dev_t>?

    private let statsLock = NSLock()
    private var stats = ScanStats()

    private let linkLock = NSLock()
    private var seenLinks = Set<InodeKey>()

    private static let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name)!

    init(scanner: Scanner, allowedDevices: Set<dev_t>?) {
        self.scanner = scanner
        self.allowedDevices = allowedDevices
    }

    func snapshot() -> ScanStats { statsLock.withLock { stats } }

    private func flush(_ c: inout Counters, path: String) {
        statsLock.withLock {
            stats.items += c.items
            stats.bytes += c.bytes
            stats.errors += c.errors
            stats.currentPath = path
        }
        c = Counters()
    }

    /// True the first time a given (dev, inode) is seen; hard links count once, like du.
    private func firstSighting(dev: dev_t, ino: ino_t) -> Bool {
        linkLock.withLock { seenLinks.insert(InodeKey(dev: dev, ino: ino)).inserted }
    }

    /// Worker thread body.
    func work() {
        var scratch: [FileNode] = []
        var subdirs: [Job] = []
        var counters = Counters()
        while let job = queue.pop() {
            if !scanner.isCancelled {
                read(job, into: &scratch, subdirs: &subdirs, counters: &counters)
                flush(&counters, path: job.path)
            }
            queue.complete(adding: subdirs)
            subdirs.removeAll(keepingCapacity: true)
        }
    }

    /// open(2) a directory; for paths longer than PATH_MAX, walk them in chunks with openat(2).
    static func openDirectory(_ path: String, followSymlink: Bool) -> Int32 {
        var flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
        if !followSymlink { flags |= O_NOFOLLOW }
        let fd = open(path, flags)
        if fd >= 0 || errno != ENAMETOOLONG { return fd }

        let bytes = Array(path.utf8)
        let limit = Int(PATH_MAX) - 1
        var dirFD = AT_FDCWD
        var start = 0
        while start < bytes.count {
            var end = min(start + limit, bytes.count)
            if end < bytes.count {
                // Split on a "/" so each chunk is a valid relative path.
                guard let slash = bytes[start..<end].lastIndex(of: UInt8(ascii: "/")), slash > start else {
                    if dirFD != AT_FDCWD { close(dirFD) }
                    errno = ENAMETOOLONG
                    return -1
                }
                end = slash
            }
            let chunk = String(decoding: bytes[start..<end], as: UTF8.self)
            let next = openat(dirFD, chunk, flags)
            let savedErrno = errno
            if dirFD != AT_FDCWD { close(dirFD) }
            guard next >= 0 else { errno = savedErrno; return -1 }
            dirFD = next
            start = end + 1
        }
        return dirFD
    }

    private func read(_ job: Job, into scratch: inout [FileNode], subdirs: inout [Job],
                      counters: inout Counters) {
        let dirNode = job.node
        let fd = Walk.openDirectory(job.path, followSymlink: job.followSymlink)
        guard fd >= 0 else {
            dirNode.errorCount = 1
            counters.errors += 1
            return
        }
        // Security: the path was built when the parent was listed, possibly much earlier and on
        // another thread. If any component was swapped for a symlink since, open() could land
        // somewhere else — so require the opened directory to be the exact one we listed.
        if let expected = job.expected {
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_dev == expected.dev, opened.st_ino == expected.ino else {
                close(fd)
                dirNode.errorCount = 1
                counters.errors += 1
                return
            }
        }
        guard let dir = fdopendir(fd) else {
            close(fd)
            dirNode.errorCount = 1
            counters.errors += 1
            return
        }
        defer { closedir(dir) }   // also closes fd

        let prefix = job.path.hasSuffix("/") ? job.path : job.path + "/"
        var st = stat()
        var seen = 0

        while true {
            errno = 0
            guard let ent = readdir(dir) else {
                // NULL with errno set is an I/O error mid-listing, not the end: flag the partial result.
                if errno != 0 { dirNode.errorCount = 1; counters.errors += 1 }
                break
            }
            let namePtr = (UnsafeRawPointer(ent) + Walk.nameOffset).assumingMemoryBound(to: CChar.self)
            let nameLength = Int(ent.pointee.d_namlen)
            if namePtr[0] == 0x2E && (nameLength == 1 || (nameLength == 2 && namePtr[1] == 0x2E)) {
                continue   // "." and ".."
            }
            seen += 1
            if seen & 4095 == 0 {
                // Keep progress and cancellation responsive inside huge directories.
                if scanner.isCancelled { break }
                flush(&counters, path: job.path)
            }

            // Names that aren't valid UTF-8 (possible on some non-APFS volumes) can't be represented
            // exactly in a String path. Keep a lossy display name but flag the item and never
            // descend into it, so a mangled path can't be used to read or trash a different file.
            let validName = String(validatingCString: namePtr)
            let name = validName ?? String(decoding: UnsafeRawBufferPointer(start: namePtr, count: nameLength),
                                           as: UTF8.self)

            guard fstatat(fd, namePtr, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                let node = FileNode(name: name, isDirectory: false, isSymlink: false,
                                    diskSize: 0, apparentSize: 0, mtime: 0, parent: dirNode)
                node.errorCount = 1
                scratch.append(node)
                counters.items += 1
                counters.errors += 1
                continue
            }

            let type = st.st_mode & S_IFMT
            let isDir = type == S_IFDIR
            var disk = Int64(st.st_blocks) * 512
            var apparent = Int64(st.st_size)
            if !isDir && st.st_nlink > 1 && !firstSighting(dev: st.st_dev, ino: st.st_ino) {
                disk = 0
                apparent = 0
            }

            var childPath: String?
            if isDir {
                let p = prefix + name
                if Scanner.skipPaths.contains(p) { continue }
                childPath = p
            }

            let node = FileNode(name: name, isDirectory: isDir, isSymlink: type == S_IFLNK,
                                diskSize: disk, apparentSize: apparent,
                                mtime: Int(st.st_mtimespec.tv_sec), parent: dirNode)
            scratch.append(node)
            counters.items += 1
            counters.bytes += disk

            if validName == nil {
                node.errorCount = 1
                counters.errors += 1
                continue
            }
            if let childPath, allowedDevices?.contains(st.st_dev) ?? true {
                subdirs.append(Job(node: node, path: childPath, followSymlink: false,
                                   expected: FileID(dev: st.st_dev, ino: st.st_ino)))
            }
        }

        // Copy into an exactly-sized array so `scratch` stays uniquely owned and keeps its
        // capacity for the next directory. (`Array(scratch)` would share scratch's buffer,
        // and removeAll(keepingCapacity:) would then allocate a full-size buffer per directory.)
        var children: [FileNode] = []
        children.reserveCapacity(scratch.count)
        children.append(contentsOf: scratch)
        dirNode.children = children
        scratch.removeAll(keepingCapacity: true)
    }
}
