import Foundation
import os.lock
import Darwin

final class InodeTracker: @unchecked Sendable {
    private let shardCount = 64
    private let mask: Int
    private let locks: UnsafeMutableBufferPointer<os_unfair_lock>
    private let locksBase: UnsafeMutablePointer<os_unfair_lock>
    private let sets: UnsafeMutablePointer<Set<UInt64>>
    private let bloomFilter: UnsafeMutablePointer<Int64>
    private let bloomSlots = 8 * 1024
    private let bloomMask: UInt64

    init() {
        self.mask = shardCount - 1
        self.bloomMask = UInt64(bloomSlots * 64 - 1)

        let buffer = UnsafeMutableBufferPointer<os_unfair_lock>.allocate(capacity: shardCount)
        buffer.initialize(repeating: os_unfair_lock())
        self.locks = buffer
        self.locksBase = buffer.baseAddress!

        let setsPtr = UnsafeMutablePointer<Set<UInt64>>.allocate(capacity: shardCount)
        for i in 0..<shardCount {
            setsPtr.advanced(by: i).initialize(to: Set<UInt64>(minimumCapacity: 1024))
        }
        self.sets = setsPtr

        self.bloomFilter = .allocate(capacity: bloomSlots)
        self.bloomFilter.initialize(repeating: 0, count: bloomSlots)
    }

    deinit {
        for i in 0..<shardCount {
            sets.advanced(by: i).deinitialize(count: 1)
        }
        sets.deallocate()
        locks.deallocate()
        bloomFilter.deallocate()
    }

    @inline(__always)
    func visit(inode: UInt64) -> Bool {
        let shardIndex = Int(inode) & mask
        os_unfair_lock_lock(locksBase + shardIndex)
        let (inserted, _) = sets[shardIndex].insert(inode)
        os_unfair_lock_unlock(locksBase + shardIndex)
        return inserted
    }

    @inline(__always)
    func visit(device: dev_t, inode: ino_t) -> Bool {
        let key = (UInt64(device) << 32) | UInt64(inode)

        let h1 = key & bloomMask
        let h2 = ((key >> 16) ^ (key << 16)) & bloomMask

        let word1 = Int(h1 >> 6)
        let bit1 = Int64(1 << (h1 & 63))
        let word2 = Int(h2 >> 6)
        let bit2 = Int64(1 << (h2 & 63))

        let existing1 = bloomFilter[word1]
        let existing2 = bloomFilter[word2]

        if (existing1 & bit1) == 0 || (existing2 & bit2) == 0 {
            atomicOr(bloomFilter.advanced(by: word1), bit1)
            if word1 != word2 {
                atomicOr(bloomFilter.advanced(by: word2), bit2)
            }

            let shardIndex = Int(key) & mask
            os_unfair_lock_lock(locksBase + shardIndex)
            sets[shardIndex].insert(key)
            os_unfair_lock_unlock(locksBase + shardIndex)
            return true
        }

        let shardIndex = Int(key) & mask
        os_unfair_lock_lock(locksBase + shardIndex)
        let (inserted, _) = sets[shardIndex].insert(key)
        os_unfair_lock_unlock(locksBase + shardIndex)
        return inserted
    }

    func reset() {
        memset(bloomFilter, 0, bloomSlots * MemoryLayout<Int64>.size)
        for i in 0..<shardCount {
            os_unfair_lock_lock(locksBase + i)
            sets[i].removeAll(keepingCapacity: true)
            os_unfair_lock_unlock(locksBase + i)
        }
    }
}
