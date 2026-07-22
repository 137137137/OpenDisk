import Foundation
import Synchronization

/// Shared scan counters, updated once per directory (never per file), so a
/// single fast lock stays effectively uncontended even with dozens of
/// workers hammering the filesystem.
final class ScanMetrics: Sendable {

    private struct Counters {
        var scannedBytes: Int64 = 0
        var itemsScanned: Int64 = 0
        var unreadableDirectories = 0
    }

    private let state = Mutex(Counters())

    /// Directories the scan failed to open so far.
    var unreadableDirectories: Int {
        state.withLock { $0.unreadableDirectories }
    }

    /// Records one directory the scan could not open.
    func addUnreadable() {
        state.withLock { $0.unreadableDirectories += 1 }
    }

    /// Records one directory's worth of results.
    func add(bytes: Int64, items: Int) {
        state.withLock {
            $0.scannedBytes += bytes
            $0.itemsScanned += Int64(items)
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
                itemsScanned: Int($0.itemsScanned)
            )
        }
    }
}
