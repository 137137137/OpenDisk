import Foundation
import Darwin

// MARK: - Directory Work Item and Node

struct DirectoryWorkItem {
    let path: String
    let depth: Int
    let parentId: UUID?
    let id: UUID = UUID()
}

class DirectoryNode: @unchecked Sendable {
    let id: UUID
    let path: String
    let name: String
    var size: Int64 = 0
    var itemCount: Int = 0
    var modTime: Date = Date.distantPast
    var children: [FolderItem] = []
    var isCompleted = false
    let parentId: UUID?
    
    init(id: UUID, path: String, name: String, parentId: UUID?) {
        self.id = id
        self.path = path
        self.name = name
        self.parentId = parentId
    }
}

// MARK: - Thread Pool and Worker Management

final class HighPerformanceThreadPool: @unchecked Sendable {
    private let maxWorkers: Int
    private let queue = DispatchQueue(label: "ThreadPool", qos: .userInitiated, attributes: .concurrent)
    private let semaphore: DispatchSemaphore
    
    init() {
        self.maxWorkers = min(ProcessInfo.processInfo.processorCount, 8)
        self.semaphore = DispatchSemaphore(value: maxWorkers)
    }
    
    func execute<T>(_ task: @Sendable @escaping () throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.semaphore.wait()
                defer { self.semaphore.signal() }
                
                do {
                    let result = try task()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - System Directory Filter moved to SharedTypes.swift

// MARK: - Inode Tracking

class ShardedInodeSet: @unchecked Sendable {
    private let shardCount = 16
    private var shards: [Set<FileDeviceInode>]
    private let locks: [NSLock]
    
    init() {
        self.shards = Array(repeating: Set<FileDeviceInode>(), count: shardCount)
        self.locks = (0..<shardCount).map { _ in NSLock() }
    }
    
    func insert(_ devIno: FileDeviceInode) -> Bool {
        let shardIndex = abs(devIno.hashValue) % shardCount
        locks[shardIndex].lock()
        defer { locks[shardIndex].unlock() }
        
        let (inserted, _) = shards[shardIndex].insert(devIno)
        return inserted
    }
    
    func contains(_ devIno: FileDeviceInode) -> Bool {
        let shardIndex = abs(devIno.hashValue) % shardCount
        locks[shardIndex].lock()
        defer { locks[shardIndex].unlock() }
        
        return shards[shardIndex].contains(devIno)
    }
}

// MARK: - FileID Tracking moved to SharedTypes.swift

// MARK: - Firmlink Resolver moved to SharedTypes.swift

// MARK: - Rate Model moved to SharedTypes.swift