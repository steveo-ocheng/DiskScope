import Foundation
import Testing
@testable import DiskScope

private let GB: Int64 = 1_000_000_000

/// A Mac-like APFS layout: container disk3 (1000 GB, 400 GB free) plus an external disk.
private let macMounts: [MountInfo] = [
    MountInfo(mountPoint: "/", device: "/dev/disk3s3s1", fsType: "apfs", total: 1000 * GB, free: 400 * GB),
    MountInfo(mountPoint: "/dev", device: "devfs", fsType: "devfs", total: 0, free: 0),
    MountInfo(mountPoint: "/System/Volumes/VM", device: "/dev/disk3s6", fsType: "apfs", total: 1000 * GB, free: 400 * GB),
    MountInfo(mountPoint: "/System/Volumes/Preboot", device: "/dev/disk3s4", fsType: "apfs", total: 1000 * GB, free: 400 * GB),
    MountInfo(mountPoint: "/System/Volumes/Data", device: "/dev/disk3s1", fsType: "apfs", total: 1000 * GB, free: 400 * GB),
    MountInfo(mountPoint: "/System/Volumes/Update/mnt1", device: "/dev/disk3s3", fsType: "apfs", total: 1000 * GB, free: 400 * GB),
    MountInfo(mountPoint: "/System/Volumes/xarts", device: "/dev/disk1s2", fsType: "apfs", total: GB / 2, free: GB / 4),
    MountInfo(mountPoint: "/Volumes/Recovery", device: "/dev/disk3s5", fsType: "apfs", total: 1000 * GB, free: 400 * GB),
    MountInfo(mountPoint: "/Volumes/.timemachine/x/2026.backup", device: "com.apple.TimeMachine.2026.backup@/dev/disk3s1",
              fsType: "apfs", total: 1000 * GB, free: 400 * GB),
    MountInfo(mountPoint: "/Volumes/Backup", device: "/dev/disk9s1", fsType: "hfs", total: 2000 * GB, free: 500 * GB),
]

private let volumeUsed: [String: Int64] = [
    "/": 19 * GB, "/System/Volumes/Data": 540 * GB, "/System/Volumes/VM": 2 * GB,
    "/System/Volumes/Preboot": 22 * GB, "/System/Volumes/Update/mnt1": 19 * GB, "/Volumes/Recovery": 3 * GB,
]

private func compute(root: String, scanned: Int64, stayOnDevice: Bool = false,
                     mounts: [MountInfo] = macMounts) -> HiddenSpace? {
    HiddenSpace.compute(root: root, volumeName: "Macintosh HD", scanned: scanned, unreadable: 7,
                        stayOnDevice: stayOnDevice, mounts: mounts, purgeable: 30 * GB, snapshots: 4,
                        spaceUsed: { volumeUsed[$0] }, displayName: { HiddenSpace.displayName(forMount: $0) })
}

@Suite("Hidden space")
struct HiddenSpaceTests {
    @Test func parsesAPFSDeviceNames() {
        #expect(HiddenSpace.apfsIDs("/dev/disk3s1")! == ("disk3", "disk3s1"))
        #expect(HiddenSpace.apfsIDs("/dev/disk3s3s1")! == ("disk3", "disk3s3"))   // sealed system snapshot
        #expect(HiddenSpace.apfsIDs("/dev/disk12s2")! == ("disk12", "disk12s2"))
        #expect(HiddenSpace.apfsIDs("com.apple.TimeMachine.x@/dev/disk3s1") == nil)
        #expect(HiddenSpace.apfsIDs("devfs") == nil)
        #expect(HiddenSpace.apfsIDs("/dev/disk3") == nil)
        #expect(HiddenSpace.apfsIDs("/dev/diskXsY") == nil)
        #expect(HiddenSpace.apfsIDs("//server/share") == nil)
    }

    @Test func onlyWholeDiskScansAreMeasured() {
        #expect(compute(root: "/Users/me", scanned: 10 * GB) == nil)
        #expect(compute(root: "/", scanned: 10 * GB) != nil)
    }

    @Test func startupDiskScanListsOtherVolumesInTheContainer() throws {
        // Default scan of / walks into VM and Preboot (they're mounted inside it) and sees Data
        // through firmlinks; Recovery lives under /Volumes, which is skipped.
        let h = try #require(compute(root: "/", scanned: 500 * GB))
        #expect(h.used == 600 * GB)
        #expect(h.otherVolumes.map(\.mountPoint) == ["/Volumes/Recovery"])
        #expect(h.otherVolumesTotal == 3 * GB)
        #expect(h.invisible == 97 * GB)
        #expect(h.total == 100 * GB)
        #expect(h.purgeable == 30 * GB && h.snapshots == 4 && h.unreadable == 7)
        #expect(!h.scannedExceedsUsed)
    }

    @Test func stayOnDeviceLeavesNestedVolumesOut() throws {
        let h = try #require(compute(root: "/", scanned: 500 * GB, stayOnDevice: true))
        // Biggest first; the Update mnt1 mount is the system volume again, so it's not listed;
        // the Time Machine snapshot mount and the other container's xarts are ignored.
        #expect(h.otherVolumes.map(\.mountPoint) == ["/System/Volumes/Preboot", "/Volumes/Recovery", "/System/Volumes/VM"])
        #expect(h.otherVolumes.first?.name == "Preboot (startup files)")
        #expect(h.otherVolumesTotal == 27 * GB)
        #expect(h.invisible == 73 * GB)
    }

    @Test func scanningTheDataVolumeDirectlyCountsTheSystemVolumeAsOther() throws {
        let h = try #require(compute(root: "/System/Volumes/Data", scanned: 520 * GB))
        #expect(h.otherVolumes.map(\.mountPoint).contains("/"))
        #expect(h.otherVolumes.first { $0.mountPoint == "/" }?.name == "macOS (system volume)")
        #expect(!h.otherVolumes.map(\.mountPoint).contains("/System/Volumes/Data"))
    }

    @Test func nonAPFSDiskHasNoSiblingVolumes() throws {
        let h = try #require(compute(root: "/Volumes/Backup", scanned: 1400 * GB))
        #expect(h.used == 1500 * GB)
        #expect(h.otherVolumes.isEmpty)
        #expect(h.invisible == 100 * GB)
    }

    @Test func filesAddingUpToMoreThanUsedClampToZero() throws {
        // APFS clones share storage, so the scanned total can exceed what the disk reports.
        let h = try #require(compute(root: "/Volumes/Backup", scanned: 1600 * GB))
        #expect(h.invisible == 0)
        #expect(h.total == 0)
        #expect(h.scannedExceedsUsed)
    }

    @Test func coverageRulesMirrorTheScanner() {
        #expect(HiddenSpace.isCovered("/", root: "/", stayOnDevice: true))
        #expect(HiddenSpace.isCovered("/System/Volumes/Data", root: "/", stayOnDevice: true))
        #expect(HiddenSpace.isCovered("/System/Volumes/VM", root: "/", stayOnDevice: false))
        #expect(!HiddenSpace.isCovered("/System/Volumes/VM", root: "/", stayOnDevice: true))
        #expect(!HiddenSpace.isCovered("/Volumes/Recovery", root: "/", stayOnDevice: false))
        #expect(!HiddenSpace.isCovered("/System/Volumes/Update/mnt1", root: "/", stayOnDevice: false))
        #expect(!HiddenSpace.isCovered("/dev", root: "/", stayOnDevice: false))
        #expect(HiddenSpace.isCovered("/Volumes/Ext/nested", root: "/Volumes/Ext", stayOnDevice: false))
        #expect(!HiddenSpace.isCovered("/Volumes/Extra", root: "/Volumes/Ext", stayOnDevice: false))
    }

    @Test func measuresTheRealStartupDisk() throws {
        let mounts = HiddenSpace.currentMounts()
        let root = try #require(mounts.first { $0.mountPoint == "/" })
        #expect(root.total > 0)
        #expect(HiddenSpace.volumeSpaceUsed("/").map { $0 > 0 } == true)
        let h = try #require(HiddenSpace.measure(root: "/", scanned: 1, unreadable: 0, stayOnDevice: false))
        #expect(h.used > 0)
        #expect(h.total <= h.used)
        #expect(!h.volumeName.isEmpty)
        #expect(HiddenSpace.measure(root: NSHomeDirectory(), scanned: 1, unreadable: 0, stayOnDevice: false) == nil)
        #expect(HiddenSpace.localSnapshotCount("/") >= 0)
        #expect(HiddenSpace.volumeSpaceUsed("/no/such/mount/\(UUID())") == nil)
    }
}
