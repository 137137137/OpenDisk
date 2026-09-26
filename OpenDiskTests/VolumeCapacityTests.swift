import Foundation
import Testing
@testable import OpenDisk

@Suite("Volume capacity")
struct VolumeCapacityTests {
    @Test("available includes purgeable space like Finder does")
    func includesPurgeable() {
        let capacity = VolumeCapacity(
            total: 994_000_000_000, free: 46_000_000_000,
            availableForImportantUsage: 93_000_000_000
        )
        #expect(capacity.available == 93_000_000_000)
        #expect(capacity.purgeable == 47_000_000_000)
        #expect(capacity.used == 901_000_000_000)
    }

    @Test("falls back to free space when the system reports nothing better")
    func fallsBackToFree() {
        let missing = VolumeCapacity(total: 500, free: 120)
        #expect(missing.available == 120)
        #expect(missing.purgeable == 0)
        let lower = VolumeCapacity(total: 500, free: 120, availableForImportantUsage: 80)
        #expect(lower.available == 120)
    }

    @Test("available never exceeds the disk size")
    func clampedToTotal() {
        let capacity = VolumeCapacity(total: 500, free: 100, availableForImportantUsage: 900)
        #expect(capacity.available == 500)
        #expect(capacity.used == 0)
    }

    @Test("the boot volume reports at least its free space as available")
    func liveBootVolume() throws {
        let capacity = try #require(DeviceMonitor.volumeCapacity(ofPath: "/"))
        #expect(capacity.available >= capacity.free)
        #expect(capacity.available <= capacity.total)
        #expect(capacity.purgeable >= 0)
    }
}
