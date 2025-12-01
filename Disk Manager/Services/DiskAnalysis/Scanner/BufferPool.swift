import Foundation
import os.lock

final class BufferPool: @unchecked Sendable {
    private let bufferSize: Int
    private let poolSize: Int
    private let state: OSAllocatedUnfairLock<PoolState>

    struct PoolState {
        var pool: UnsafeMutablePointer<UnsafeMutableRawPointer?>
        var head: Int
        let poolSize: Int
    }

    init(bufferSize: Int, poolSize: Int = 256) {
        self.bufferSize = bufferSize
        self.poolSize = poolSize

        let pool = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: poolSize)
        for i in 0..<poolSize {
            pool[i] = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        }

        self.state = OSAllocatedUnfairLock(initialState: PoolState(pool: pool, head: 0, poolSize: poolSize))
    }

    deinit {
        state.withLockUnchecked { state in
            for i in 0..<state.head {
                state.pool[i]?.deallocate()
            }
            state.pool.deallocate()
        }
    }

    @inline(__always)
    func acquire() -> UnsafeMutableRawPointer {
        state.withLockUnchecked { state in
            if state.head > 0 {
                state.head -= 1
                return state.pool[state.head]!
            }
            return UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        }
    }

    @inline(__always)
    func release(_ buffer: UnsafeMutableRawPointer) {
        let shouldDeallocate = state.withLockUnchecked { state -> Bool in
            if state.head < state.poolSize {
                state.pool[state.head] = buffer
                state.head += 1
                return false
            }
            return true
        }

        if shouldDeallocate {
            buffer.deallocate()
        }
    }
}
