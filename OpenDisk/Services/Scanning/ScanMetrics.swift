import Foundation

final class ScanMetrics: Sendable {
    private struct Counters {
        var scannedBytes: Int64 = 0
        var itemsScanned: Int64 = 0
        var unreadableDirectories = 0
        var phase: ScanPhase = .scanning
        var stepsCompleted = 0
        var stepsTotal = 0
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

    func beginSteps(total: Int) {
        state.withLock {
            $0.stepsCompleted = 0
            $0.stepsTotal = total
        }
    }

    func completeStep() {
        state.withLock { $0.stepsCompleted = min($0.stepsCompleted + 1, $0.stepsTotal) }
    }

    func reset(bytes: Int64 = 0, items: Int = 0) {
        state.withLock {
            $0.scannedBytes = bytes
            $0.itemsScanned = Int64(items)
            $0.stepsCompleted = 0
            $0.stepsTotal = 0
        }
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
                phase: $0.phase,
                stepsCompleted: $0.stepsCompleted,
                stepsTotal: $0.stepsTotal
            )
        }
    }
}
