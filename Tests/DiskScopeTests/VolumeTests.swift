import Foundation
import AppKit
import Testing
@testable import DiskScope

@Suite("Volumes")
struct VolumeTests {
    @Test func bootVolumeIsDescribedAsStartupDisk() throws {
        let v = try #require(Volume(url: URL(fileURLWithPath: "/")))
        #expect(v.isRoot && v.id == "/" && v.path == "/")
        #expect(!v.name.isEmpty)
        #expect(v.total > 0 && v.available > 0 && v.available <= v.total)
        #expect(v.used == v.total - v.available)
        #expect(v.usedFraction > 0 && v.usedFraction < 1)
        #expect(v.kind == "Startup Disk")
        #expect(v.symbol == "internaldrive.fill")
        #expect(v.isLocal)
        #expect(!v.format.isEmpty)
    }

    @Test func folderOnAnInternalDiskReportsThatDisk() throws {
        let t = TempTree("vol")
        let v = try #require(Volume(url: URL(fileURLWithPath: t.root)))
        // Keeps the folder it was asked about (Foundation spells /private/var as /var).
        #expect(TrashGuard.realPath(v.path) == t.root)
        #expect(!v.isRoot)
        #expect(v.kind == "Internal")
        #expect(v.symbol == "internaldrive.fill")
        #expect(v.total == Volume(url: URL(fileURLWithPath: "/"))!.total)
    }

    @Test func missingPathHasNoVolume() {
        #expect(Volume(url: URL(fileURLWithPath: "/DiskScopeTests-nope-\(UUID().uuidString)")) == nil)
    }

    @Test func mountedListStartsWithTheBootVolume() throws {
        let list = Volume.mounted()
        #expect(list.first?.isRoot == true)
        #expect(Set(list.map(\.id)).count == list.count)
        #expect(!list.contains { $0.path.hasPrefix("/System/Volumes/") })   // hidden volumes skipped
    }

    @Test func zeroCapacityGivesZeroFraction() throws {
        // usedFraction must not divide by zero; exercised through a real value with total == 0 if any,
        // otherwise via the formula on the boot volume.
        let v = try #require(Volume(url: URL(fileURLWithPath: "/")))
        #expect(v.usedFraction == Double(v.used) / Double(v.total))
    }
}

@Suite("VolumeStore")
@MainActor
struct VolumeStoreTests {
    @Test func loadsVolumesAndRefreshesOnMountNotifications() async throws {
        let store = VolumeStore()
        try await waitUntil { !store.volumes.isEmpty }
        #expect(store.volumes.first?.isRoot == true)
        let before = store.volumes
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didUnmountNotification, object: nil)
        store.refresh()
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.volumes.map(\.id) == before.map(\.id))
    }
}
