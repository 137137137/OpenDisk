import Foundation

/// What a running scan is doing right now; drives the status bar's wording
/// during the stretch before any item has been counted.
enum ScanPhase: Equatable, Sendable {
    /// Consulting the previous scan's cache and FSEvents journal to find
    /// what changed — no filesystem items are being counted yet.
    case checkingChanges
    /// Reading the filesystem.
    case scanning
}

/// A point-in-time snapshot of a running scan.
struct ScanProgress: Equatable, Sendable {
    let scannedBytes: Int64
    let itemsScanned: Int
    var phase: ScanPhase = .scanning
}
