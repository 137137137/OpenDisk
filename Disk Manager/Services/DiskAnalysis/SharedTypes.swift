import Foundation
import Darwin

// MARK: - Shared Types for Disk Analysis Services

struct RateModel {
    var estTotalFiles: Int = 100_000
    var lastUpdate: Date = Date()
    var filesProcessed: Int = 0
    var bytesProcessed: Int64 = 0
}

class ShardedFileIDSet {
    private let shards: [FileIDShard]
    private let shardCount: Int
    
    init(shardCount: Int = 16) {
        self.shardCount = shardCount
        self.shards = (0..<shardCount).map { _ in FileIDShard() }
    }
    
    func insert(_ data: Data) -> Bool {
        let hash = data.djb2Hash()
        let shardIndex = Int(hash) % shardCount
        return shards[shardIndex].insert(data)
    }
}

class FileIDShard {
    private var seen = Set<Data>()
    private let lock = NSLock()
    
    func insert(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(data).inserted
    }
}

extension Data {
    func djb2Hash() -> UInt32 {
        var hash: UInt32 = 5381
        for byte in self {
            hash = ((hash << 5) &+ hash) &+ UInt32(byte)
        }
        return hash
    }
}

struct FileDeviceInode: Equatable, Hashable {
    let dev: UInt32
    let ino: UInt64
}

class FirmlinkResolver {
    private let firmlinksPath = "/usr/share/firmlinks"
    
    func canonicalize(_ path: String) -> String {
        return path
    }
}

struct SystemDirectoryFilter {
    static func prioritizedPaths(from paths: [String]) -> [String] {
        let importantPaths = [
            "/Users",
            "/Applications", 
            "/System",
            "/Library"
        ]
        
        var prioritized: [String] = []
        var remaining: [String] = []
        
        for path in paths {
            if importantPaths.contains(path) {
                prioritized.append(path)
            } else {
                remaining.append(path)
            }
        }
        
        return prioritized + remaining.sorted()
    }
    
    static func shouldSkipPath(_ path: String) -> Bool {
        let skipPaths = [
            "/dev", "/proc", "/sys", "/tmp", "/var/folders",
            "/.Spotlight-V100", "/.fseventsd", "/.Trashes",
            "/System/Volumes/Data", "/Network", "/Volumes/.timemachine"
        ]
        
        return skipPaths.contains { path.hasPrefix($0) }
    }
}

struct DirectoryEntry {
    let name: String
    let isDir: Bool
    let allocSize: Int64
    let deviceId: UInt32
    let inode: UInt64
}

// MARK: - Bulk Scanning Types

struct BulkAttrBuf {
    var length: UInt32
    var objType: UInt32
    var deviceId: UInt32
    var fileId: UInt64
    var allocSize: Int64
    var nameRef: attrreference_t
}

struct BulkScanEntry {
    let name: String
    let isDir: Bool
    let allocSize: Int64
    let inode: UInt64
    let deviceId: UInt32
}

struct OptimizedScanEntry {
    let actualName: String
    let isDir: Bool
    let allocSize: Int64
    let fileId: UInt64
    let deviceId: UInt32
}

// MARK: - Autoreleasepool for Async Contexts

/// Autoreleasepool wrapper for async contexts to prevent memory buildup
func asyncAutoreleasePool<T>(_ body: @escaping () async -> T) async -> T {
    return await withTaskGroup(of: T.self) { group in
        group.addTask {
            await body()
        }
        return await group.next()!
    }
}

