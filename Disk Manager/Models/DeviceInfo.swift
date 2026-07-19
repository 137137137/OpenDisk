import Foundation

/// A scannable device shown in the sidebar: the boot volume group or an
/// external volume.
struct DeviceInfo: Identifiable, Hashable, Sendable {
    /// The scan path is unique per device and stable across refreshes, so
    /// sidebar selection survives device-list rebuilds.
    var id: String { path }

    let name: String
    /// SF Symbol name for the sidebar row.
    let icon: String
    /// Path scanned when the device is selected.
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
