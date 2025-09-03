import Foundation
import Darwin

// MARK: - Utility Structures

struct BulkEntry {
    let name: String
    let isDir: Bool
    let allocSize: Int64
    let inode: UInt64
    let deviceId: UInt32
}

struct DevIno: Hashable {
    let dev: UInt32
    let ino: UInt64
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(dev)
        hasher.combine(ino)
    }
}

struct ReadDirEntry {
    let name: String
    let type: UInt8
    let ino: UInt64
}

struct OptimizedBulkEntry {
    let actualName: String
    let isDir: Bool
    let allocSize: Int64
    let fileId: UInt64
    let deviceId: UInt32
}

struct DiskUsage {
    var totalSize: Int64 = 0
    var fileCount: Int = 0
    var directoryCount: Int = 0
    var ignoredCount: Int = 0
    
    mutating func add(size: Int64, isDirectory: Bool) {
        totalSize += size
        if isDirectory {
            directoryCount += 1
        } else {
            fileCount += 1
        }
    }
}

struct EWMA {
    private var value: Double = 0.0
    private let alpha: Double
    private var initialized: Bool = false
    
    init(alpha: Double = 0.1) {
        self.alpha = alpha
    }
    
    mutating func update(_ newValue: Double) {
        if !initialized {
            value = newValue
            initialized = true
        } else {
            value = alpha * newValue + (1 - alpha) * value
        }
    }
    
    var smoothedValue: Double {
        return value
    }
}

// MARK: - Filesystem Utilities

func getFilesystemType(path: String) -> String? {
    return path.withCString { pathCStr in
        var fs = statfs()
        guard statfs(pathCStr, &fs) == 0 else { return nil }
        return withUnsafePointer(to: fs.f_fstypename) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 16) { cStr in
                String(cString: cStr)
            }
        }
    }
}

func isPathSafeForOptimizedScan(_ path: String) -> Bool {
    // Check filesystem type using POSIX statfs (faster than URLResourceValues)
    guard let fsType = getFilesystemType(path: path) else { return false }
    
    // Only use optimized scan on APFS and HFS+ filesystems
    let safeFSTypes = ["apfs", "hfs"]
    if !safeFSTypes.contains(fsType.lowercased()) {
        return false
    }
    
    // Be conservative - only use optimized scan on well-known safe directories
    let safePaths = [
        "/Applications", "/Users", "/Library", "/usr/local", "/opt"
    ]
    
    // Only allow optimization on explicitly safe paths and their subdirectories
    var isSafePath = false
    for safePath in safePaths {
        if path == safePath || path.hasPrefix(safePath + "/") {
            isSafePath = true
            break
        }
    }
    
    if !isSafePath {
        return false
    }
    
    // Additional checks for known problematic subdirectories
    let problematicPaths = [
        "/Library/Trial", "/Library/Bluetooth", "/Library/Caches/com.apple.",
        "/Users/Shared/.com.apple.", "/usr/local/var/db"
    ]
    
    for problematicPath in problematicPaths {
        if path.hasPrefix(problematicPath) {
            return false
        }
    }
    
    return true
}

// MARK: - Extensions

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}