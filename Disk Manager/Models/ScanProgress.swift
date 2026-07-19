import Foundation

/// A point-in-time snapshot of a running scan.
struct ScanProgress: Equatable, Sendable {
    let scannedBytes: Int64
    let itemsScanned: Int
}
