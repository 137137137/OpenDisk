import Foundation
import Synchronization

final class ScanMetrics: Sendable {
    private struct Counters {
        var scannedBytes: Int64 = 0
        var itemsScanned: Int64 = 0
        var unreadableDirectories = 0
        var phase: ScanPhase = .scanning
    }

    private let state = Mutex(Counters())

    func setPhase(_ phase: ScanPhase) {
        state.withLock { $0.phase = phase }
    }

    var unreadableDirectories: Int {
        state.withLock { $0.unreadableDirectories }
    }

    func addUnreadable() {
        state.withLock { $0.unreadableDirectories += 1 }
    }

    func add(bytes: Int64, items: Int) {
        state.withLock {
            $0.scannedBytes += bytes
            $0.itemsScanned += Int64(items)
        }
    }

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
                itemsScanned: Int($0.itemsScanned),
                phase: $0.phase
            )
        }
    }
}
