import Foundation
import Darwin

// MARK: - Directory Work Item and Node

struct DirectoryWorkItem {
    let path: String
    let depth: Int
    let parentId: UUID?
    let id: UUID = UUID()
}

class DirectoryNode {
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

// MARK: - System Directory Filter

struct SystemDirectoryFilter {
    static func shouldSkipPath(_ path: String) -> Bool {
        let skipPaths = [
            "/dev", "/proc", "/sys", "/tmp", "/var/folders",
            "/.Spotlight-V100", "/.fseventsd", "/.Trashes",
            "/System/Volumes/Data", "/Network", "/Volumes/.timemachine"
        ]
        
        return skipPaths.contains { path.hasPrefix($0) }
    }
    
    static func prioritizedPaths(from paths: [String]) -> [String] {
        let priority1 = ["/Users", "/Applications", "/Library"]
        let priority2 = ["/usr", "/opt", "/System"]
        
        var result: [String] = []
        
        // Add priority 1 paths first
        for priorityPath in priority1 {
            if let found = paths.first(where: { $0 == priorityPath }) {
                result.append(found)
            }
        }
        
        // Add priority 2 paths
        for priorityPath in priority2 {
            if let found = paths.first(where: { $0 == priorityPath }) {
                result.append(found)
            }
        }
        
        // Add remaining paths
        for path in paths {
            if !result.contains(path) {
                result.append(path)
            }
        }
        
        return result
    }
}

// MARK: - Inode Tracking

class ShardedInodeSet: @unchecked Sendable {
    private let shardCount = 16
    private var shards: [Set<DevIno>]
    private let locks: [NSLock]
    
    init() {
        self.shards = Array(repeating: Set<DevIno>(), count: shardCount)
        self.locks = (0..<shardCount).map { _ in NSLock() }
    }
    
    func insert(_ devIno: DevIno) -> Bool {
        let shardIndex = abs(devIno.hashValue) % shardCount
        locks[shardIndex].lock()
        defer { locks[shardIndex].unlock() }
        
        let (inserted, _) = shards[shardIndex].insert(devIno)
        return inserted
    }
    
    func contains(_ devIno: DevIno) -> Bool {
        let shardIndex = abs(devIno.hashValue) % shardCount
        locks[shardIndex].lock()
        defer { locks[shardIndex].unlock() }
        
        return shards[shardIndex].contains(devIno)
    }
}

// MARK: - Rate Model for Progress Tracking

class RateModel {
    var estTotalFiles: Int = 100_000
    var processedFiles: Int = 0
    var startTime: Date = Date()
    
    func updateEstimate(newCount: Int) {
        if newCount > estTotalFiles {
            estTotalFiles = max(estTotalFiles * 2, newCount * 3)
        }
    }
    
    var estimatedCompletion: TimeInterval? {
        guard processedFiles > 0 else { return nil }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let rate = Double(processedFiles) / elapsed
        let remaining = Double(estTotalFiles - processedFiles)
        
        return remaining / rate
    }
}