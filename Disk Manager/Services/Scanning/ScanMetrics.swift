import Foundation

/// Shared scan counters, updated once per directory (never per file), so a
/// single fast lock stays effectively uncontended even with dozens of
/// workers hammering the filesystem.
final class ScanMetrics: Sendable {

    private struct Counters {
        var scannedBytes: Int64 = 0
        var itemsScanned: Int64 = 0
        var totalUsedBytes: Int64 = 0
        var currentPath: String = ""
    }

    private let state = Locked(Counters())

    /// Sets the denominator used for the progress fraction.
    func setTotalUsedBytes(_ bytes: Int64) {
        state.withLock { $0.totalUsedBytes = bytes }
    }

    /// Records one directory's worth of results.
    func add(bytes: Int64, items: Int, currentPath: String? = nil) {
        state.withLock {
            $0.scannedBytes += bytes
            $0.itemsScanned += Int64(items)
            if let currentPath { $0.currentPath = currentPath }
        }
    }

    /// Rolls back previously recorded results (used when a catalog scan
    /// restarts after the volume changed mid-search).
    func subtract(bytes: Int64, items: Int) {
        state.withLock {
            $0.scannedBytes -= bytes
            $0.itemsScanned -= Int64(items)
        }
    }

    func snapshot() -> ScanProgress {
        state.withLock {
            ScanProgress(
                scannedBytes: $0.scannedBytes,
                totalUsedBytes: $0.totalUsedBytes,
                itemsScanned: Int($0.itemsScanned),
                currentPath: $0.currentPath
            )
        }
    }
}
