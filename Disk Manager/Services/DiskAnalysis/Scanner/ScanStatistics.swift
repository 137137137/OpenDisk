import Foundation
import os.lock

/// Aggregated scan counters. Updated once per getattrlistbulk batch (not per
/// file), so a single unfair lock is uncontended in practice.
final class ScanStatistics: Sendable {
    private struct Counters {
        var scannedBytes: Int64 = 0
        var itemsScanned: Int64 = 0
        var totalUsedBytes: Int64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: Counters())

    @inline(__always)
    func add(bytes: Int64, items: Int) {
        state.withLock { counters in
            counters.scannedBytes += bytes
            counters.itemsScanned += Int64(items)
        }
    }

    func setTotalBytes(_ bytes: Int64) {
        state.withLock { $0.totalUsedBytes = bytes }
    }

    func snapshot(path: String) -> HyperScanProgress {
        let counters = state.withLock { $0 }
        return HyperScanProgress(
            scannedBytes: counters.scannedBytes,
            totalUsedBytes: counters.totalUsedBytes,
            currentPath: path,
            itemsScanned: Int(counters.itemsScanned)
        )
    }

    func reset() {
        state.withLock { counters in
            counters.scannedBytes = 0
            counters.itemsScanned = 0
        }
    }
}
