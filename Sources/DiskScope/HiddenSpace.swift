import Foundation
import Darwin

/// Space a disk reports as used that a scan of it didn't find in files: the "where did my
/// space go?" gap. On APFS it's mostly other volumes sharing the disk (swap, Preboot,
/// Recovery…), local snapshots, folders the scan couldn't read, and filesystem metadata.
struct HiddenSpace: Equatable, Sendable {
    struct Part: Equatable, Sendable, Identifiable {
        let name: String
        let mountPoint: String
        let bytes: Int64
        var id: String { mountPoint }
    }

    let volumeName: String
    /// Used space on the disk (APFS: the whole container), purgeable space included.
    let used: Int64
    /// Disk usage of the scanned files.
    let scanned: Int64
    /// Volumes on the same disk that the scan didn't walk through.
    let otherVolumes: [Part]
    /// Part of `used` that macOS frees by itself when space runs low.
    let purgeable: Int64
    /// Local (Time Machine) snapshots on the volume; their space is in `invisible`.
    let snapshots: Int
    /// Items the scan couldn't read; their space is in `invisible`.
    let unreadable: Int

    var otherVolumesTotal: Int64 { otherVolumes.reduce(0) { $0 + $1.bytes } }
    /// Used space found neither in scanned files nor in other volumes.
    var invisible: Int64 { max(0, used - scanned - otherVolumesTotal) }
    /// Everything that's used but not in the scan.
    var total: Int64 { otherVolumesTotal + invisible }
    /// The files add up to more than the disk's used space (APFS clones share storage).
    var scannedExceedsUsed: Bool { scanned > used - otherVolumesTotal }
}

/// One mounted filesystem, as reported by getfsstat.
struct MountInfo: Equatable, Sendable {
    let mountPoint: String
    let device: String      // f_mntfromname, e.g. "/dev/disk3s1"
    let fsType: String      // "apfs", "hfs", "exfat", "smbfs"…
    let total: Int64        // capacity (APFS: the container's)
    let free: Int64         // free space (APFS: the container's), purgeable counted as used
}

extension HiddenSpace {
    /// Measures the gap for a finished scan. Returns nil unless `root` is a mount point (only a
    /// whole-disk scan can be compared with the disk's used space). Blocking: call off the main thread.
    static func measure(root: String, scanned: Int64, unreadable: Int, stayOnDevice: Bool) -> HiddenSpace? {
        let mounts = currentMounts()
        guard let rootMount = mounts.first(where: { $0.mountPoint == root }) else { return nil }
        let isAPFS = rootMount.fsType == "apfs"
        var purgeable: Int64 = 0
        var name = (root as NSString).lastPathComponent
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        if let v = try? URL(fileURLWithPath: root).resourceValues(forKeys: keys) {
            name = v.volumeLocalizedName ?? name
            if let important = v.volumeAvailableCapacityForImportantUsage, let raw = v.volumeAvailableCapacity {
                purgeable = max(0, important - Int64(raw))
            }
        }
        return compute(root: root, volumeName: name, scanned: scanned, unreadable: unreadable,
                       stayOnDevice: stayOnDevice, mounts: mounts, purgeable: purgeable,
                       snapshots: isAPFS ? localSnapshotCount(root) : 0,
                       spaceUsed: volumeSpaceUsed, displayName: displayName(forMount:))
    }

    /// The pure part of `measure`, separated so it can be tested with made-up mounts.
    static func compute(root: String, volumeName: String, scanned: Int64, unreadable: Int, stayOnDevice: Bool,
                        mounts: [MountInfo], purgeable: Int64, snapshots: Int,
                        spaceUsed: (String) -> Int64?, displayName: (String) -> String) -> HiddenSpace? {
        guard let rootMount = mounts.first(where: { $0.mountPoint == root }) else { return nil }
        let used = max(0, rootMount.total - rootMount.free)
        var others: [Part] = []
        if rootMount.fsType == "apfs", let (container, rootVolume) = apfsIDs(rootMount.device) {
            // Volumes the scan walked through (or that are the same volume mounted twice).
            var covered: Set<String> = [rootVolume]
            for m in mounts where isCovered(m.mountPoint, root: root, stayOnDevice: stayOnDevice) {
                if let ids = apfsIDs(m.device), ids.container == container { covered.insert(ids.volume) }
            }
            var listed = covered
            for m in mounts.sorted(by: { $0.mountPoint < $1.mountPoint }) where m.fsType == "apfs" {
                guard let ids = apfsIDs(m.device), ids.container == container,
                      listed.insert(ids.volume).inserted,
                      let bytes = spaceUsed(m.mountPoint), bytes > 0 else { continue }
                others.append(Part(name: displayName(m.mountPoint), mountPoint: m.mountPoint, bytes: bytes))
            }
            others.sort { $0.bytes > $1.bytes }
        }
        return HiddenSpace(volumeName: volumeName, used: used, scanned: scanned, otherVolumes: others,
                           purgeable: min(purgeable, used), snapshots: snapshots, unreadable: unreadable)
    }

    /// Whether a scan of `root` walks into the volume mounted at `mountPoint` (mirrors Scanner's rules).
    static func isCovered(_ mountPoint: String, root: String, stayOnDevice: Bool) -> Bool {
        if mountPoint == root { return true }
        // The Data volume's contents appear under / through firmlinks (/Users, /Applications…).
        if root == "/" && mountPoint == "/System/Volumes/Data" { return true }
        if stayOnDevice { return false }
        guard mountPoint.hasPrefix(root == "/" ? "/" : root + "/") else { return false }
        return !Scanner.skipPaths.contains { mountPoint == $0 || mountPoint.hasPrefix($0 + "/") }
    }

    /// "/dev/disk3s1s1" → (container "disk3", volume "disk3s1"). Snapshot mounts ("name@/dev/…")
    /// and non-disk devices return nil.
    static func apfsIDs(_ device: String) -> (container: String, volume: String)? {
        guard device.hasPrefix("/dev/disk") else { return nil }
        let parts = device.dropFirst("/dev/disk".count).split(separator: "s", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.prefix(2).allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return ("disk\(parts[0])", "disk\(parts[0])s\(parts[1])")
    }

    static func displayName(forMount path: String) -> String {
        switch path {
        case "/": return "macOS (system volume)"
        case "/System/Volumes/Data": return "Data volume"
        case "/System/Volumes/VM": return "VM (swap and sleep image)"
        case "/System/Volumes/Preboot": return "Preboot (startup files)"
        case "/System/Volumes/Update": return "Update (software updates)"
        default:
            let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeLocalizedNameKey])
            return v?.volumeLocalizedName ?? (path as NSString).lastPathComponent
        }
    }

    // MARK: System queries

    static func currentMounts() -> [MountInfo] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let capacity = Int(count) + 8 // room for mounts that appear in between the two calls
        let buf = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { buf.deallocate() }
        let n = getfsstat(buf, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard n > 0 else { return [] }
        return (0..<Int(n)).map { i in
            var s = buf[i]
            let bsize = Int64(s.f_bsize)
            return MountInfo(mountPoint: cString(&s.f_mntonname), device: cString(&s.f_mntfromname),
                             fsType: cString(&s.f_fstypename),
                             total: Int64(s.f_blocks) * bsize, free: Int64(s.f_bfree) * bsize)
        }
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// Space used by one APFS volume (what `df` shows as Used), via getattrlist(ATTR_VOL_SPACEUSED).
    static func volumeSpaceUsed(_ mountPoint: String) -> Int64? {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buf = [UInt8](repeating: 0, count: 32)
        let r = buf.withUnsafeMutableBytes { getattrlist(mountPoint, &attrs, $0.baseAddress, $0.count, 0) }
        guard r == 0 else { return nil }
        // Layout: u_int32_t length, then the off_t value (4-byte aligned).
        return buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    }

    /// Number of local snapshots (`tmutil listlocalsnapshots`), or 0 if it can't be determined.
    static func localSnapshotCount(_ mountPoint: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["listlocalsnapshots", mountPoint]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return 0 }
        final class Output: @unchecked Sendable { var data = Data() } // written once, read after `done`
        let output = Output()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut { p.terminate(); return 0 }
        p.waitUntilExit()
        return String(decoding: output.data, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("com.apple.") }.count
    }
}
