import Foundation
import Darwin

final class ScanStatistics: @unchecked Sendable {
    private let _scannedBytes: UnsafeMutablePointer<Int64>
    private let _itemsScanned: UnsafeMutablePointer<Int64>
    private let _totalUsedBytes: UnsafeMutablePointer<Int64>

    init() {
        _scannedBytes = .allocate(capacity: 1)
        _scannedBytes.initialize(to: 0)
        _itemsScanned = .allocate(capacity: 1)
        _itemsScanned.initialize(to: 0)
        _totalUsedBytes = .allocate(capacity: 1)
        _totalUsedBytes.initialize(to: 0)
    }

    deinit {
        _scannedBytes.deallocate()
        _itemsScanned.deallocate()
        _totalUsedBytes.deallocate()
    }

    @inline(__always)
    func add(bytes: Int64, items: Int) {
        if bytes > 0 {
            OSAtomicAdd64(bytes, _scannedBytes)
        }
        if items > 0 {
            OSAtomicAdd64(Int64(items), _itemsScanned)
        }
    }

    @inline(__always)
    func setTotalBytes(_ bytes: Int64) {
        _totalUsedBytes.pointee = bytes
        OSMemoryBarrier()
    }

    @inline(__always)
    func snapshot(path: String) -> HyperScanProgress {
        HyperScanProgress(
            scannedBytes: _scannedBytes.pointee,
            totalUsedBytes: _totalUsedBytes.pointee,
            currentPath: path,
            itemsScanned: Int(_itemsScanned.pointee)
        )
    }

    func reset() {
        while OSAtomicCompareAndSwap64(_scannedBytes.pointee, 0, _scannedBytes) == false {}
        while OSAtomicCompareAndSwap64(_itemsScanned.pointee, 0, _itemsScanned) == false {}
    }
}
