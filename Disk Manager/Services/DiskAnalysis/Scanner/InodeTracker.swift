import Foundation
import os.lock
import Darwin

/// Tracks visited (device, inode) pairs to avoid double-counting hard-linked
/// files. The scanner only consults this for files with nlink > 1, so the sets
/// stay small and contention is negligible.
final class InodeTracker: @unchecked Sendable {
    private static let shardCount = 16
    private let mask = shardCount - 1
    private let shards: [OSAllocatedUnfairLock<Set<UInt64>>]

    init() {
        shards = (0..<Self.shardCount).map { _ in
            OSAllocatedUnfairLock(initialState: Set<UInt64>(minimumCapacity: 256))
        }
    }

    /// Returns true the first time a (device, inode) pair is seen.
    @inline(__always)
    func visit(device: dev_t, inode: ino_t) -> Bool {
        let key = (UInt64(bitPattern: Int64(device)) << 32) | UInt64(inode)
        return shards[Int(inode) & mask].withLock { set in
            set.insert(key).inserted
        }
    }

    func reset() {
        for shard in shards {
            shard.withLock { $0.removeAll(keepingCapacity: true) }
        }
    }
}
