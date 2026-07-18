import Foundation
import os.lock

/// Recycles the raw buffers used for getattrlistbulk reads.
///
/// Buffers are allocated lazily on first use, so the pool's memory footprint
/// tracks actual scan concurrency instead of a worst-case preallocation.
final class BufferPool: @unchecked Sendable {
    private let bufferSize: Int
    private let maxPooled: Int
    private let pool: OSAllocatedUnfairLock<[UnsafeMutableRawPointer]>

    init(bufferSize: Int, poolSize: Int = 64) {
        self.bufferSize = bufferSize
        self.maxPooled = poolSize
        self.pool = OSAllocatedUnfairLock(uncheckedState: [])
    }

    deinit {
        pool.withLockUnchecked { buffers in
            for buffer in buffers {
                buffer.deallocate()
            }
            buffers.removeAll()
        }
    }

    @inline(__always)
    func acquire() -> UnsafeMutableRawPointer {
        if let buffer = pool.withLockUnchecked({ $0.popLast() }) {
            return buffer
        }
        return UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    }

    @inline(__always)
    func release(_ buffer: UnsafeMutableRawPointer) {
        let pooled = pool.withLockUnchecked { buffers -> Bool in
            if buffers.count < maxPooled {
                buffers.append(buffer)
                return true
            }
            return false
        }

        if !pooled {
            buffer.deallocate()
        }
    }
}
