import Foundation

/// A point-in-time snapshot of a running scan.
struct ScanProgress: Sendable {
    let scannedBytes: Int64
    let totalUsedBytes: Int64
    let itemsScanned: Int
    /// The directory most recently entered by any scan worker.
    let currentPath: String

    /// Progress as a fraction from 0.0 to 1.0.
    var fractionCompleted: Double {
        guard totalUsedBytes > 0 else { return 0 }
        return min(Double(scannedBytes) / Double(totalUsedBytes), 1.0)
    }
}
