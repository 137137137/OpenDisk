import Foundation

struct DeviceInfo: Identifiable, Hashable, Sendable {
    var id: String { path }

    let name: String
    let icon: String
    let path: String
    let totalBytes: Int64
    let availableBytes: Int64

    var usedBytes: Int64 { totalBytes - availableBytes }

    var formattedTotalStorage: String {
        ByteFormatter.formatDecimalNoFraction(totalBytes)
    }

    var formattedUsedStorage: String {
        ByteFormatter.formatDecimalNoFraction(usedBytes)
    }
}

struct VolumeCapacity: Hashable, Sendable {
    let total: Int64
    let available: Int64
    let free: Int64

    init(total: Int64, free: Int64, availableForImportantUsage: Int64? = nil) {
        self.total = total
        self.free = free
        self.available = min(total, max(free, availableForImportantUsage ?? 0))
    }

    var used: Int64 { total - available }
    var purgeable: Int64 { available - free }
}
