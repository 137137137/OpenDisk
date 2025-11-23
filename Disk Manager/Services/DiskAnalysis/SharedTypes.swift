import Foundation
import Darwin

// MARK: - Shared Types for Disk Analysis Services

struct RateModel {
    var estTotalFiles: Int = 100_000
    var lastUpdate: Date = Date()
    var filesProcessed: Int = 0
    var bytesProcessed: Int64 = 0
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

