import Foundation
import CoreServices

/// Real-time file system monitoring using Apple's FSEvents API
/// Provides efficient change notifications to avoid expensive full rescans
class FileSystemMonitor {
    private var eventStream: FSEventStreamRef?
    private var monitoredPaths: [String] = []
    private var isMonitoring = false
    public var changeHandler: ((FileSystemChange) -> Void)?
    
    struct FileSystemChange {
        let path: String
        let eventFlags: FSEventStreamEventFlags
        let isCreated: Bool
        let isRemoved: Bool
        let isRenamed: Bool
        let isModified: Bool
        let isDirectory: Bool
        
        init(path: String, flags: FSEventStreamEventFlags) {
            self.path = path
            self.eventFlags = flags
            
            // Parse event flags for easier usage
            self.isCreated = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0
            self.isRemoved = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0
            self.isRenamed = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0
            self.isModified = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0
            self.isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        }
    }
    
    /// Start monitoring the specified paths for changes
    /// - Parameters:
    ///   - paths: Array of paths to monitor
    ///   - latency: Time interval to batch events (in seconds)
    ///   - onChangeHandler: Closure called when file system changes occur
    func startMonitoring(
        paths: [String],
        latency: TimeInterval = 1.0,
        onChangeHandler: @escaping (FileSystemChange) -> Void
    ) {
        guard !isMonitoring else { return }
        
        self.monitoredPaths = paths
        self.changeHandler = onChangeHandler
        
        // Create FSEventStream context
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        // Create the event stream
        let pathsToWatch = paths as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagIgnoreSelf
        )
        
        eventStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        )
        
        guard let stream = eventStream else {
            print("Failed to create FSEventStream")
            return
        }
        
        // Use dispatch queue instead of deprecated run loop scheduling
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        
        // Start the stream
        if FSEventStreamStart(stream) {
            isMonitoring = true
            print("Started monitoring paths: \(paths)")
        } else {
            print("Failed to start FSEventStream")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
    }
    
    /// Stop monitoring file system changes
    func stopMonitoring() {
        guard let stream = eventStream, isMonitoring else { return }
        
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        
        eventStream = nil
        isMonitoring = false
        changeHandler = nil
        
        print("Stopped monitoring file system changes")
    }
    
    deinit {
        stopMonitoring()
    }
}

// MARK: - FSEvents Callback

private func fsEventCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    
    let monitor = Unmanaged<FileSystemMonitor>.fromOpaque(info).takeUnretainedValue()
    
    // Extract paths using proper FSEvents API
    let pathsPtr = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    
    // Process events on the main actor
    Task { @MainActor in
        for i in 0..<numEvents {
            let pathCString = pathsPtr[i]
            let path = String(cString: pathCString)
            let flags = eventFlags[i]
            
            let change = FileSystemMonitor.FileSystemChange(path: path, flags: flags)
            monitor.changeHandler?(change)
        }
    }
}

// MARK: - Directory Cache Manager

/// Manages cached directory information and updates based on file system events  
class DirectoryCacheManager {
    private var sizeCache: [String: Int64] = [:]
    private var itemCountCache: [String: Int] = [:]
    private var lastModifiedCache: [String: Date] = [:]
    private let fileSystemMonitor = FileSystemMonitor()
    
    /// Get cached size for a directory
    func getCachedSize(for path: String) -> Int64? {
        return sizeCache[path]
    }
    
    /// Set cached size for a directory
    func setCachedSize(_ size: Int64, for path: String) {
        sizeCache[path] = size
    }
    
    /// Get cached item count for a directory
    func getCachedItemCount(for path: String) -> Int? {
        return itemCountCache[path]
    }
    
    /// Set cached item count for a directory
    func setCachedItemCount(_ count: Int, for path: String) {
        itemCountCache[path] = count
    }
    
    /// Start monitoring for changes and update cache accordingly
    func startMonitoring(paths: [String], onCacheInvalidated: @escaping (String) -> Void) {
        fileSystemMonitor.startMonitoring(paths: paths) { [weak self] change in
            self?.handleFileSystemChange(change, onCacheInvalidated: onCacheInvalidated)
        }
    }
    
    /// Stop monitoring
    func stopMonitoring() {
        fileSystemMonitor.stopMonitoring()
    }
    
    /// Clear all cached data
    func clearCache() {
        sizeCache.removeAll()
        itemCountCache.removeAll()
        lastModifiedCache.removeAll()
    }
    
    /// Handle file system changes and update cache
    private func handleFileSystemChange(
        _ change: FileSystemMonitor.FileSystemChange,
        onCacheInvalidated: @escaping (String) -> Void
    ) {
        let affectedPath = change.path
        let parentPath = URL(fileURLWithPath: affectedPath).deletingLastPathComponent().path
        
        // Invalidate cache for the affected directory and its parent
        let pathsToInvalidate = [affectedPath, parentPath]
        
        for path in pathsToInvalidate {
            if sizeCache[path] != nil || itemCountCache[path] != nil {
                sizeCache.removeValue(forKey: path)
                itemCountCache.removeValue(forKey: path)
                lastModifiedCache.removeValue(forKey: path)
                
                print("Cache invalidated for: \(path) due to change: \(change.path)")
                onCacheInvalidated(path)
            }
        }
        
        // For created/removed files, we need to invalidate parent directories all the way up
        if change.isCreated || change.isRemoved {
            invalidateParentDirectories(of: affectedPath, onCacheInvalidated: onCacheInvalidated)
        }
    }
    
    /// Recursively invalidate parent directory caches
    private func invalidateParentDirectories(of path: String, onCacheInvalidated: @escaping (String) -> Void) {
        var currentPath = path
        let rootPath = "/"
        
        while currentPath != rootPath {
            currentPath = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
            
            if sizeCache[currentPath] != nil || itemCountCache[currentPath] != nil {
                sizeCache.removeValue(forKey: currentPath)
                itemCountCache.removeValue(forKey: currentPath)
                lastModifiedCache.removeValue(forKey: currentPath)
                
                onCacheInvalidated(currentPath)
            }
            
            if currentPath == "/" { break }
        }
    }
}

// MARK: - Smart Cache with FSEvents Integration

/// Enhanced caching system that integrates with FSEvents for automatic invalidation
@MainActor
class SmartDirectoryCache {
    private let cacheManager = DirectoryCacheManager()
    private var folderTreeCache: [String: [FolderItem]] = [:]
    private var activeScans: Set<String> = []
    
    /// Cache folder tree for a path
    func cacheFolderTree(_ items: [FolderItem], for path: String) {
        folderTreeCache[path] = items
        
        // Also cache sizes for all items
        for item in items {
            cacheManager.setCachedSize(item.size, for: item.path)
            cacheManager.setCachedItemCount(item.itemCount, for: item.path)
        }
    }
    
    /// Get cached folder tree
    func getCachedFolderTree(for path: String) -> [FolderItem]? {
        return folderTreeCache[path]
    }
    
    /// Start monitoring for automatic cache invalidation
    func startSmartMonitoring(for paths: [String], onInvalidation: @escaping (String) -> Void) {
        cacheManager.startMonitoring(paths: paths) { [weak self] invalidatedPath in
            self?.folderTreeCache.removeValue(forKey: invalidatedPath)
            onInvalidation(invalidatedPath)
        }
    }
    
    /// Stop monitoring
    func stopMonitoring() {
        cacheManager.stopMonitoring()
    }
    
    /// Check if a scan is already active for a path
    func isScanActive(for path: String) -> Bool {
        return activeScans.contains(path)
    }
    
    /// Mark scan as active
    func markScanActive(for path: String) {
        activeScans.insert(path)
    }
    
    /// Mark scan as completed
    func markScanCompleted(for path: String) {
        activeScans.remove(path)
    }
    
    /// Clear all caches
    func clearAllCaches() {
        folderTreeCache.removeAll()
        cacheManager.clearCache()
        activeScans.removeAll()
    }
}