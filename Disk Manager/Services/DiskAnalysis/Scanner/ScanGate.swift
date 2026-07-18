import Foundation

/// Bounds the number of concurrent blocking directory reads.
///
/// Benchmarks show APFS metadata operations contend heavily in the kernel:
/// beyond ~8 concurrent getattrlistbulk readers, total system CPU rises 3-4x
/// while wall time gets *worse*. Waiting tasks suspend here (no thread is
/// blocked), so an unlimited task fan-out is safe while actual syscall
/// concurrency stays in the sweet spot.
actor ScanGate {
    private var available: Int
    private var waiters: [UnsafeContinuation<Void, Never>] = []

    init(width: Int) {
        available = width
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withUnsafeContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
