import Foundation
import Darwin

// MARK: - Bulk Metadata Optimization

struct BulkEntry {
    let name: String
    let isDir: Bool
    let allocSize: Int64
    let inode: UInt64
    let deviceId: UInt32
}

struct DevIno: Hashable {
    let dev: UInt64
    let ino: UInt64
    
    init(dev: UInt64, ino: UInt64) {
        self.dev = dev
        self.ino = ino
    }
}

// Get real device and inode using fstatat for proper hard link deduplication
func getDevIno(for path: String) -> DevIno? {
    return path.withCString { pathCStr in
        var stat = Darwin.stat()
        guard lstat(pathCStr, &stat) == 0 else { return nil }
        return DevIno(dev: UInt64(stat.st_dev), ino: stat.st_ino)
    }
}

// Get allocated bytes from st_blocks * 512 (more efficient than totalFileAllocatedSizeKey)
func getAllocatedSize(for path: String) -> Int64 {
    return path.withCString { pathCStr in
        var stat = Darwin.stat()
        guard lstat(pathCStr, &stat) == 0 else { return 0 }
        return Int64(stat.st_blocks) * 512  // st_blocks is in 512-byte units
    }
}

// File descriptor-based directory operations to avoid repeated path resolution
func openDirectoryFd(path: String) -> Int32? {
    return path.withCString { pathCStr in
        let fd = open(pathCStr, O_RDONLY)
        return fd >= 0 ? fd : nil
    }
}

func getStatAt(dirFd: Int32, name: String) -> (dev: UInt64, ino: UInt64, blocks: Int64)? {
    return name.withCString { nameCStr in
        var stat = Darwin.stat()
        guard fstatat(dirFd, nameCStr, &stat, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return (dev: UInt64(stat.st_dev), ino: stat.st_ino, blocks: Int64(stat.st_blocks))
    }
}

// High-performance bulk metadata using getattrlistbulk(2) system call
func bulkList(at path: String) throws -> [BulkEntry] {
    return try path.withCString { pathCStr in
        let fd = open(pathCStr, O_RDONLY)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        defer { close(fd) }
        
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_DEVID | ATTR_CMN_FILEID)
        
        var buffer = [UInt8](repeating: 0, count: 64 * 1024) // 64KB buffer
        var result: [BulkEntry] = []
        result.reserveCapacity(1000)
        
        repeat {
            let count = getattrlistbulk(fd, &attrList, &buffer, buffer.count, UInt64(FSOPT_PACK_INVAL_ATTRS))
            guard count >= 0 else {
                if errno == ENOENT { break }
                throw POSIXError(.init(rawValue: errno)!)
            }
            
            if count == 0 { break }
            
            var offset = 0
            for _ in 0..<count {
                let entryLength = buffer.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.advanced(by: offset).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
                }
                
                guard offset + Int(entryLength) <= buffer.count else { break }
                
                let entryData = buffer[offset..<offset + Int(entryLength)]
                if let entry = parseAttrBuf(Array(entryData), basePath: pathCStr) {
                    result.append(entry)
                }
                
                offset += Int(entryLength)
            }
        } while true
        
        return result
    }
}

private func parseAttrBuf(_ buffer: [UInt8], basePath: UnsafePointer<CChar>) -> BulkEntry? {
    guard buffer.count >= 16 else { return nil }
    
    var offset = 4 // Skip length
    
    // Read object type
    let objType = buffer.withUnsafeBytes { bytes in
        bytes.load(fromByteOffset: offset, as: UInt32.self)
    }
    offset += 4
    
    // Read device ID
    let deviceId = buffer.withUnsafeBytes { bytes in
        bytes.load(fromByteOffset: offset, as: UInt32.self)
    }
    offset += 4
    
    // Read inode
    let inode = buffer.withUnsafeBytes { bytes in
        bytes.load(fromByteOffset: offset, as: UInt64.self)
    }
    offset += 8
    
    // Read name length and name
    guard offset + 4 < buffer.count else { return nil }
    let nameLength = buffer.withUnsafeBytes { bytes in
        bytes.load(fromByteOffset: offset, as: UInt32.self)
    }
    offset += 4
    
    guard offset + Int(nameLength) <= buffer.count else { return nil }
    let nameData = Data(buffer[offset..<offset + Int(nameLength)])
    guard let name = String(data: nameData, encoding: .utf8) else { return nil }
    
    let isDir = (objType & UInt32(DT_DIR)) != 0
    let isSymlink = (objType & UInt32(DT_LNK)) != 0
    
    // Skip symlinks
    if isSymlink { return nil }
    
    // Get allocated size using stat() for better accuracy
    let fullPath = String(cString: basePath) + "/" + name
    let allocSize = getAllocatedSize(for: fullPath)
    
    return BulkEntry(
        name: name,
        isDir: isDir,
        allocSize: allocSize,
        inode: inode,
        deviceId: deviceId
    )
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

struct DiskUsage {
    var fileCount = 0
    var totalAllocated = 0
    
    // Convenience accessors for consistency
    var size: Int64 { Int64(totalAllocated) }
    var itemCount: Int { fileCount }
    
    mutating func addSize(_ bytes: Int64) {
        totalAllocated += Int(bytes)
    }
    
    mutating func addItem() {
        fileCount += 1
    }
}

// MARK: - Adaptive Progress Tracking

struct EWMA {
    var v = 0.0
    
    mutating func add(_ x: Double, alpha: Double = 0.2) {
        v = alpha * x + (1 - alpha) * v
    }
}

final class RateModel {
    var files = EWMA()
    var bytes = EWMA()
    var estTotalFiles: Double = 50_000 // start modestly
    private var lastUpdateTime: Date?
    private var lastFileCount: Int = 0
    
    func update(observedFiles: Int, observedBytes: Int64, currentTime: Date = Date()) {
        defer {
            lastUpdateTime = currentTime
            lastFileCount = observedFiles
        }
        
        guard let lastTime = lastUpdateTime else {
            lastUpdateTime = currentTime
            lastFileCount = observedFiles
            return
        }
        
        let elapsed = currentTime.timeIntervalSince(lastTime)
        guard elapsed > 0 else { return }
        
        let deltaFiles = observedFiles - lastFileCount
        guard deltaFiles > 0 else { return }
        
        // Update EWMA rates
        files.add(Double(deltaFiles) / elapsed)
        bytes.add(Double(observedBytes) / elapsed)
        
        // Adjust total estimate toward observed * multiplier, but allow downward movement with inertia
        let implied = max(10_000.0, Double(observedFiles) * 1.6)
        estTotalFiles = 0.9 * estTotalFiles + 0.1 * implied
    }
    
    func getProgress(processedFiles: Int) -> Double {
        return min(99.0, Double(processedFiles) / estTotalFiles * 100.0)
    }
    
    func getETA(processedFiles: Int) -> TimeInterval? {
        guard files.v > 0, processedFiles > 0 else { return nil }
        let remainingFiles = max(0, estTotalFiles - Double(processedFiles))
        return remainingFiles / files.v
    }
    
    func getCurrentRate() -> (filesPerSec: Double, bytesPerSec: Double) {
        return (files.v, bytes.v)
    }
}

struct FolderItem: Identifiable, Comparable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let itemCount: Int
    let lastModified: Date
    var children: [FolderItem] = []
    let isDirectory: Bool
    
    var percentage: Double = 0.0
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    var formattedItemCount: String {
        if itemCount >= 1000000 {
            return String(format: "%.1fM", Double(itemCount) / 1_000_000.0)
        } else if itemCount >= 1000 {
            return String(format: "%.1fK", Double(itemCount) / 1000.0)
        } else {
            return "\(itemCount)"
        }
    }
    
    var relativeModified: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: lastModified, relativeTo: Date())
    }
    
    static func < (lhs: FolderItem, rhs: FolderItem) -> Bool {
        return lhs.size > rhs.size // Sort by size descending
    }
}

// MARK: - Optimized Directory Enumeration

func enumerateDirectoryRecursiveBulk(at rootPath: String, seenInodes: Set<DevIno>) async -> (usage: DiskUsage, updatedInodes: Set<DevIno>) {
    var usage = DiskUsage()
    var localSeenInodes = seenInodes
    var directoriesToProcess = [rootPath]
    
    while !directoriesToProcess.isEmpty {
        let currentPath = directoriesToProcess.removeFirst()
        
        do {
            let entries = try bulkList(at: currentPath)
            
            for entry in entries {
                let devIno = DevIno(dev: UInt64(entry.deviceId), ino: entry.inode)
                
                // Skip if we've seen this inode (hard link deduplication)
                if localSeenInodes.contains(devIno) {
                    continue
                }
                localSeenInodes.insert(devIno)
                
                // Count the item
                usage.addItem()
                
                if entry.isDir {
                    // Add directory to processing queue
                    let fullPath = (currentPath as NSString).appendingPathComponent(entry.name)
                    directoriesToProcess.append(fullPath)
                } else {
                    // Add file size
                    if entry.allocSize > 0 {
                        usage.addSize(entry.allocSize)
                    }
                }
            }
            
        } catch {
            // Fall back to traditional enumeration for this directory
            let fallbackResult = await fallbackDirectoryEnumeration(at: currentPath, seenInodes: localSeenInodes)
            usage.fileCount += fallbackResult.usage.fileCount
            usage.totalAllocated += fallbackResult.usage.totalAllocated
            localSeenInodes = fallbackResult.updatedInodes
        }
    }
    
    return (usage, localSeenInodes)
}

func fallbackDirectoryEnumeration(at rootPath: String, seenInodes: Set<DevIno>) async -> (usage: DiskUsage, updatedInodes: Set<DevIno>) {
    return await Task.detached {
        var usage = DiskUsage()
        var localSeenInodes = seenInodes
        let rootURL = URL(fileURLWithPath: rootPath)
        
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey
        ]
        
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return (usage, localSeenInodes)
        }
        
        for case let url as URL in enumerator {
            autoreleasepool {
                do {
                    let resourceValues = try url.resourceValues(forKeys: Set(keys))
                    
                    // Skip symlinks
                    if resourceValues.isSymbolicLink == true {
                        return
                    }
                    
                    // Extract device and inode for deduplication
                    if let devIno = getDevIno(for: url.path) {
                        if localSeenInodes.contains(devIno) {
                            return
                        }
                        localSeenInodes.insert(devIno)
                    }
                    
                    usage.addItem()
                    
                    if resourceValues.isRegularFile == true {
                        let allocatedSize = getAllocatedSize(for: url.path)
                        usage.addSize(allocatedSize)
                    }
                    
                } catch {
                    // Skip inaccessible files
                    return
                }
            }
        }
        
        return (usage, localSeenInodes)
    }.value
}

class DiskAnalyzer: ObservableObject {
    @Published var rootItems: [FolderItem] = []
    @Published var isScanning: Bool = false
    @Published var scanProgress: String = ""
    @Published var scanProgressPercentage: Double = 0.0
    @Published var estimatedTimeRemaining: String = ""
    @Published var totalSize: Int64 = 0
    @Published var currentScanPath: String = ""
    @Published var filesPerSecond: String = ""
    @Published var externalVolumes: [FolderItem] = []
    
    private var scanTask: Task<Void, Never>?
    private var scanStartTime: Date?
    private var totalFilesProcessed: Int = 0
    private var totalBytesProcessed: Int64 = 0
    private var progressModel = RateModel()
    private var lastProgressUpdate: Date = Date()
    
    // Complete folder tree for instant navigation
    private var folderTree: [String: [FolderItem]] = [:]
    
    // Navigate to a path using pre-calculated data
    func navigateToPath(_ path: String) {
        if let preCalculatedItems = folderTree[path] {
            rootItems = preCalculatedItems
            totalSize = preCalculatedItems.reduce(0) { $0 + $1.size }
            calculatePercentages()
        }
    }
    
    func scanDirectory(_ path: String) {
        scanTask?.cancel()
        
        isScanning = true
        scanProgress = "Preparing to scan..."
        rootItems = []
        scanProgressPercentage = 0.0
        estimatedTimeRemaining = ""
        totalFilesProcessed = 0
        totalBytesProcessed = 0
        scanStartTime = Date()
        lastProgressUpdate = Date()
        currentScanPath = ""
        filesPerSecond = ""
        
        // Initialize fresh progress model
        progressModel = RateModel()
        
        // For root directory scan, request full disk access
        var scanPath = path
        
        if path == "/" {
            if !hasFullDiskAccess() {
                // Guide user to grant full disk access
                scanProgress = "Full Disk Access required. Please grant in System Settings > Privacy & Security > Full Disk Access > Add your app"
                isScanning = false
                return
            }
            scanPath = "/"
        }
        
        scanTask = Task { [weak self] in
            guard let self = self else { return }
            
            // Create local copies of captured variables to avoid concurrency issues
            let pathToScan = scanPath
            
            // Scan external volumes in parallel
            async let volumesScan: Void = self.scanExternalVolumes()
            async let diskScan: [FolderItem] = self.performScanWithProgress(path: pathToScan)
            
            let items = await diskScan
            await volumesScan
            
            let sortedItems = items.sorted()
            
            await MainActor.run {
                self.rootItems = sortedItems
                self.totalSize = sortedItems.reduce(0) { $0 + $1.size }
                self.calculatePercentages()
                self.isScanning = false
                self.scanProgress = "Scan complete"
                self.scanProgressPercentage = 100.0
                self.estimatedTimeRemaining = ""
            }
        }
    }
    
    private func performScanWithProgress(path: String) async -> [FolderItem] {
        // For root directory, build complete tree
        if path == "/" {
            await MainActor.run {
                self.scanProgress = "Building complete directory tree..."
            }
            return await buildCompleteTreeAsync()
        } else {
            // For other directories, use regular scan
            await MainActor.run {
                self.scanProgress = "Scanning directory..."
            }
            return await scanDirectoryContentsSafe(path)
        }
    }
    
    private func buildCompleteTreeAsync() async -> [FolderItem] {
        // Check Full Disk Access status first
        let hasFDA = hasFullDiskAccess()
        
        if !hasFDA {
            // Show FDA requirement message with guidance
            await MainActor.run {
                self.scanProgress = "Full Disk Access required for complete analysis"
                self.isScanning = false
            }
            return []
        }
        
        await MainActor.run {
            self.scanProgress = "Initializing disk analysis..."
            self.scanProgressPercentage = 0.0
            self.totalFilesProcessed = 0
            self.totalBytesProcessed = 0
            self.lastProgressUpdate = Date()
        }
        
        // Major system directories to show at root level (excluding /Volumes)
        let rootDirectories = [
            "/Applications",
            "/Users",
            "/System", 
            "/Library",
            "/usr",
            "/opt",
            "/private"
        ]
        
        // Create immutable copy to avoid capture issues
        let directoriesToScan = rootDirectories
        
        // Use bounded concurrency = number of cores for optimal performance
        let maxConcurrency = ProcessInfo.processInfo.activeProcessorCount
        
        return await withTaskGroup(of: FolderItem?.self) { group in
            // Start tasks for all directories
            for dirPath in directoriesToScan {
                let url = URL(fileURLWithPath: dirPath)
                
                // Check if directory exists and is accessible
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                    // Update progress to show which directory we're starting
                    await MainActor.run {
                        self.scanProgress = "Analyzing \(url.lastPathComponent)..."
                    }
                    
                    group.addTask { [weak self] in
                        return await self?.buildFolderWithCompleteChildrenFast(url: url)
                    }
                }
            }
            
            // Collect all results
            var items: [FolderItem] = []
            var completedCount = 0
            
            for await item in group {
                if let validItem = item {
                    items.append(validItem)
                    completedCount += 1
                    
                    // Update progress to show completion
                    await MainActor.run {
                        self.scanProgress = "Completed \(validItem.name) (\(completedCount)/\(directoriesToScan.count) directories)"
                    }
                }
            }
            
            return items.sorted { $0.size > $1.size }
        }
    }
    
    private func buildFolderWithCompleteChildrenFast(url: URL) async -> FolderItem? {
        // High-performance directory analysis with parallel subdirectory processing and timeout
        return await withTimeout(seconds: 30) { [weak self] in
            await self?.buildFolderWithParallelChildren(url: url, depth: 0, maxDepth: 2)
        }
    }
    
    // Timeout helper function
    private func withTimeout<T>(seconds: Double, operation: @escaping () async -> T?) async -> T? {
        return await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            
            guard let result = await group.next() else { return nil }
            group.cancelAll()
            return result
        }
    }
    
    private func buildFolderWithCompleteChildren(url: URL, maxDepth: Int) async -> FolderItem? {
        do {
            let resourceValues = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey
            ])
            
            // Skip symlinks
            if resourceValues.isSymbolicLink == true {
                return nil
            }
            
            let isDirectory = resourceValues.isDirectory ?? false
            guard isDirectory else { return nil }
            
            // First, calculate total size and item count for this directory using recursive enumeration
            let totalUsage = await directoryDiskUsage(at: url)
            
            // Get immediate children for navigation purposes
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey
                ],
                options: [.skipsPackageDescendants]
            )
            
            // Process immediate children for display
            var children: [FolderItem] = []
            
            for childURL in contents {
                do {
                    let childValues = try childURL.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .contentModificationDateKey
                    ])
                    
                    // Skip symlinks
                    if childValues.isSymbolicLink == true {
                        continue
                    }
                    
                    let childIsDirectory = childValues.isDirectory ?? false
                    let childSize: Int64
                    let childItemCount: Int
                    
                    if childIsDirectory {
                        // For directories, use disk usage calculation
                        let usage = await directoryDiskUsage(at: childURL)
                        childSize = usage.size
                        childItemCount = usage.itemCount
                    } else {
                        // Regular file
                        childSize = getAllocatedSize(for: childURL.path)
                        childItemCount = 1
                    }
                    
                    let childItem = FolderItem(
                        name: childURL.lastPathComponent,
                        path: childURL.path,
                        size: childSize,
                        itemCount: childItemCount,
                        lastModified: childValues.contentModificationDate ?? Date.distantPast,
                        isDirectory: childIsDirectory
                    )
                    
                    children.append(childItem)
                    
                } catch {
                    // Skip inaccessible items
                    continue
                }
            }
            
            // Sort children by size
            children.sort { $0.size > $1.size }
            
            // Store children in tree for navigation
            let sortedChildren = children
            await MainActor.run {
                self.folderTree[url.path] = sortedChildren
            }
            
            var item = FolderItem(
                name: url.lastPathComponent,
                path: url.path,
                size: totalUsage.size, // Use the accurate total from recursive enumeration
                itemCount: totalUsage.itemCount, // Use the accurate count from recursive enumeration
                lastModified: resourceValues.contentModificationDate ?? Date.distantPast,
                isDirectory: true
            )
            
            item.children = children
            
            return item
            
        } catch {
            // Don't create zero-byte placeholders - just skip inaccessible directories
            print("Error building folder tree for \(url.path): \(error)")
            return nil
        }
    }
    
    private func scanDirectoryContentsSafe(_ path: String) async -> [FolderItem] {
        // Check if we can access this directory
        guard FileManager.default.isReadableFile(atPath: path) else {
            print("No read access to \(path)")
            return []
        }
        
        // Try bulk metadata first, fall back to traditional enumeration if needed
        do {
            let entries = try bulkList(at: path)
            var items: [FolderItem] = []
            var seenInodes = Set<DevIno>(minimumCapacity: entries.count)
            
            for entry in entries {
                let devIno = DevIno(dev: UInt64(entry.deviceId), ino: entry.inode)
                
                // Skip if we've seen this inode (hard link deduplication)
                if seenInodes.contains(devIno) {
                    continue
                }
                seenInodes.insert(devIno)
                
                let size: Int64
                let itemCount: Int
                
                if entry.isDir {
                    let fullPath = (path as NSString).appendingPathComponent(entry.name)
                    let diskUsage = await directoryDiskUsage(at: URL(fileURLWithPath: fullPath))
                    size = diskUsage.size
                    itemCount = diskUsage.itemCount
                } else {
                    size = entry.allocSize
                    itemCount = 1
                }
                
                // Get modification date using traditional method
                let itemURL = URL(fileURLWithPath: (path as NSString).appendingPathComponent(entry.name))
                let modificationDate: Date
                do {
                    let resourceValues = try itemURL.resourceValues(forKeys: [.contentModificationDateKey])
                    modificationDate = resourceValues.contentModificationDate ?? Date.distantPast
                } catch {
                    modificationDate = Date.distantPast
                }
                
                let item = FolderItem(
                    name: entry.name,
                    path: itemURL.path,
                    size: size,
                    itemCount: itemCount,
                    lastModified: modificationDate,
                    isDirectory: entry.isDir
                )
                
                items.append(item)
            }
            
            return items.sorted { $0.size > $1.size }
            
        } catch {
            // Fall back to traditional enumeration
            return await scanDirectoryContentsFallback(path)
        }
    }
    
    private func scanDirectoryContentsFallback(_ path: String) async -> [FolderItem] {
        let rootURL = URL(fileURLWithPath: path)
        
        do {
            // Get immediate children using traditional FileManager
            let contents = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                    .fileResourceIdentifierKey
                ],
                options: [.skipsPackageDescendants]
            )
            
            var items: [FolderItem] = []
            var seenInodes = Set<DevIno>()
            
            for url in contents {
                do {
                    let resourceValues = try url.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .contentModificationDateKey,
                        .fileResourceIdentifierKey
                    ])
                    
                    // Skip symlinks
                    if resourceValues.isSymbolicLink == true {
                        continue
                    }
                    
                    // Get real device and inode for deduplication
                    if let devIno = getDevIno(for: url.path) {
                        if seenInodes.contains(devIno) {
                            continue
                        }
                        seenInodes.insert(devIno)
                    }
                    
                    let isDirectory = resourceValues.isDirectory ?? false
                    let size: Int64
                    let itemCount: Int
                    
                    if isDirectory {
                        let diskUsage = await directoryDiskUsage(at: url)
                        size = diskUsage.size
                        itemCount = diskUsage.itemCount
                    } else {
                        size = getAllocatedSize(for: url.path)
                        itemCount = 1
                    }
                    
                    let item = FolderItem(
                        name: url.lastPathComponent,
                        path: url.path,
                        size: size,
                        itemCount: itemCount,
                        lastModified: resourceValues.contentModificationDate ?? Date.distantPast,
                        isDirectory: isDirectory
                    )
                    
                    items.append(item)
                    
                } catch {
                    print("Error accessing \(url.path): \(error)")
                }
            }
            
            return items.sorted { $0.size > $1.size }
            
        } catch {
            print("Error scanning directory \(path): \(error)")
            return []
        }
    }
    
    private func buildFolderWithParallelChildren(url: URL, depth: Int, maxDepth: Int) async -> FolderItem? {
        do {
            let resourceValues = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey
            ])
            
            // Skip symlinks
            if resourceValues.isSymbolicLink == true {
                return nil
            }
            
            let isDirectory = resourceValues.isDirectory ?? false
            guard isDirectory else { return nil }
            
            // Use fast enumeration for total size calculation
            let totalUsage = await directoryDiskUsageFast(at: url)
            
            // Get immediate children for navigation - parallelize subdirectory processing
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey
                ],
                options: []
            )
            
            // Split children into batches for parallel processing
            let batchSize = max(contents.count / ProcessInfo.processInfo.activeProcessorCount, 50)
            var children: [FolderItem] = []
            
            if depth < maxDepth && contents.count > batchSize {
                // Use parallel processing for large directories
                children = await withTaskGroup(of: [FolderItem].self) { group in
                    var allChildren: [FolderItem] = []
                    
                    let batches = contents.chunked(into: batchSize)
                    for batch in batches {
                        group.addTask { [weak self] in
                            var batchChildren: [FolderItem] = []
                            for childURL in batch {
                                if let child = await self?.processSingleChild(childURL) {
                                    batchChildren.append(child)
                                }
                            }
                            return batchChildren
                        }
                    }
                    
                    while let batchResult = await group.next() {
                        allChildren.append(contentsOf: batchResult)
                    }
                    
                    return allChildren
                }
            } else {
                // Sequential processing for smaller directories or max depth
                for childURL in contents {
                    if let child = await processSingleChild(childURL) {
                        children.append(child)
                    }
                }
            }
            
            // Sort children by size
            children.sort { $0.size > $1.size }
            
            // Store children in tree for navigation
            let sortedChildren = children
            await MainActor.run {
                self.folderTree[url.path] = sortedChildren
            }
            
            var item = FolderItem(
                name: url.lastPathComponent,
                path: url.path,
                size: totalUsage.size,
                itemCount: totalUsage.itemCount,
                lastModified: resourceValues.contentModificationDate ?? Date.distantPast,
                isDirectory: true
            )
            
            item.children = children
            return item
            
        } catch {
            print("Error building folder tree for \(url.path): \(error)")
            return nil
        }
    }
    
    private func processSingleChild(_ childURL: URL) async -> FolderItem? {
        do {
            let childValues = try childURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey
            ])
            
            // Skip symlinks
            if childValues.isSymbolicLink == true {
                return nil
            }
            
            let childIsDirectory = childValues.isDirectory ?? false
            let childSize: Int64
            let childItemCount: Int
            
            if childIsDirectory {
                // For directories, use fast disk usage calculation
                let usage = await directoryDiskUsageFast(at: childURL)
                childSize = usage.size
                childItemCount = usage.itemCount
            } else {
                // Regular file
                childSize = getAllocatedSize(for: childURL.path)
                childItemCount = 1
            }
            
            return FolderItem(
                name: childURL.lastPathComponent,
                path: childURL.path,
                size: childSize,
                itemCount: childItemCount,
                lastModified: childValues.contentModificationDate ?? Date.distantPast,
                isDirectory: childIsDirectory
            )
            
        } catch {
            return nil
        }
    }
    
    private func directoryDiskUsage(at rootURL: URL) async -> DiskUsage {
        // Use optimized bulk metadata calls
        let seenInodes = Set<DevIno>(minimumCapacity: 1_000_000)
        let result = await enumerateDirectoryRecursiveBulk(at: rootURL.path, seenInodes: seenInodes)
        return result.usage
    }
    
    private func directoryDiskUsageFast(at rootURL: URL) async -> DiskUsage {
        // Use the same optimized bulk metadata calls (already fast)
        let seenInodes = Set<DevIno>(minimumCapacity: 1_000_000)
        let result = await enumerateDirectoryRecursiveBulk(at: rootURL.path, seenInodes: seenInodes)
        return result.usage
    }
    
    private func enumerateDirectoryRecursive(at rootURL: URL, seenInodes: Set<DevIno>) async -> DiskUsage {
        return await Task.detached { [weak self] in
            return autoreleasepool {
                let keys: [URLResourceKey] = [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]
                
                guard let enumerator = FileManager.default.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: keys,
                    options: [] // Include everything like baobab - no skipping
                ) else {
                    return DiskUsage()
                }
                
                var usage = DiskUsage()
                var localSeenInodes = seenInodes
                var localFilesProcessed = 0
                let updateInterval = 100 // Update progress every 100 files
                
                for case let url as URL in enumerator {
                    autoreleasepool {
                        do {
                            let resourceValues = try url.resourceValues(forKeys: Set(keys))
                            
                            // Skip symlinks entirely to avoid double counting
                            if resourceValues.isSymbolicLink == true {
                                return
                            }
                            
                            // Skip if we've seen this inode (hard link deduplication)
                            if let devIno = getDevIno(for: url.path) {
                                if localSeenInodes.contains(devIno) {
                                    return
                                }
                                localSeenInodes.insert(devIno)
                            }
                            
                            // Count all items (files and directories)
                            usage.addItem()
                            localFilesProcessed += 1
                            
                            // Only count regular files for size (directories are counted by their contents)
                            if resourceValues.isRegularFile == true {
                                let allocatedSize = getAllocatedSize(for: url.path)
                                usage.addSize(allocatedSize)
                            }
                            
                            // Update progress periodically
                            if localFilesProcessed % updateInterval == 0 {
                                let currentSize = usage.size
                                let currentPath = rootURL.path
                                Task { @MainActor [weak self] in
                                    self?.totalFilesProcessed += updateInterval
                                    self?.totalBytesProcessed = currentSize
                                    self?.updateDynamicProgress(currentPath: currentPath)
                                }
                            }
                            
                        } catch {
                            // Skip files we can't access
                            return
                        }
                    }
                }
                
                // Final update for remaining files
                if localFilesProcessed % updateInterval != 0 {
                    let remainingFiles = localFilesProcessed % updateInterval
                    let finalSize = usage.size
                    let finalPath = rootURL.path
                    Task { @MainActor [weak self] in
                        self?.totalFilesProcessed += remainingFiles
                        self?.totalBytesProcessed = finalSize
                        self?.updateDynamicProgress(currentPath: finalPath)
                    }
                }
                
                return usage
            }
        }.value
    }
    
    private func enumerateDirectoryRecursiveFast(at rootURL: URL, seenInodes: Set<DevIno>) async -> DiskUsage {
        return await Task.detached { [weak self] in
            return autoreleasepool {
            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey
            ]
            
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [] // Include everything like baobab - no skipping
            ) else {
                return DiskUsage()
            }
            
            var usage = DiskUsage()
            var localSeenInodes = seenInodes
            let updateInterval = 500 // Less frequent updates for speed
            var localFilesProcessed = 0
            
            for case let url as URL in enumerator {
                autoreleasepool {
                    do {
                        let resourceValues = try url.resourceValues(forKeys: Set(keys))
                        
                        // Skip symlinks entirely to avoid double counting
                        if resourceValues.isSymbolicLink == true {
                            return
                        }
                        
                        // Skip if we've seen this inode (hard link deduplication)
                        if let devIno = getDevIno(for: url.path) {
                            if localSeenInodes.contains(devIno) {
                                return
                            }
                            localSeenInodes.insert(devIno)
                        }
                        
                        // Count all items (files and directories)
                        usage.addItem()
                        localFilesProcessed += 1
                        
                        // Only count regular files for size (directories are counted by their contents)
                        if resourceValues.isRegularFile == true {
                            let allocatedSize = getAllocatedSize(for: url.path)
                            usage.addSize(allocatedSize)
                        }
                        
                        // Update progress less frequently for speed
                        if localFilesProcessed % updateInterval == 0 {
                            let currentSize = usage.size
                            let currentPath = rootURL.path
                            Task { @MainActor [weak self] in
                                self?.totalFilesProcessed += updateInterval
                                self?.totalBytesProcessed = currentSize
                                self?.updateDynamicProgress(currentPath: currentPath)
                            }
                        }
                        
                    } catch {
                        // Skip files we can't access
                        return
                    }
                }
            }
            
            // Final update for remaining files
            if localFilesProcessed % updateInterval != 0 {
                let remainingFiles = localFilesProcessed % updateInterval
                let finalSize = usage.size
                let finalPath = rootURL.path
                Task { @MainActor [weak self] in
                    self?.totalFilesProcessed += remainingFiles
                    self?.totalBytesProcessed = finalSize
                    self?.updateDynamicProgress(currentPath: finalPath)
                }
            }
            
            return usage
            }
        }.value
    }
    
    private func updateDynamicProgress(currentPath: String) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastProgressUpdate)
        
        // Update adaptive progress model every 0.3 seconds minimum for responsiveness
        if elapsed > 0.3 && totalFilesProcessed > 0 {
            // Update rate model with current observations
            progressModel.update(
                observedFiles: totalFilesProcessed,
                observedBytes: totalBytesProcessed,
                currentTime: now
            )
            
            // Get adaptive progress percentage (can go down if estimate improves)
            scanProgressPercentage = progressModel.getProgress(processedFiles: totalFilesProcessed)
            
            // Show current path being scanned
            let pathComponent = URL(fileURLWithPath: currentPath).lastPathComponent
            currentScanPath = pathComponent
            
            // Get current processing rates
            let rates = progressModel.getCurrentRate()
            filesPerSecond = formatRate(rates.filesPerSec)
            
            // Update main progress message with rate and current location
            scanProgress = "Scanning \(pathComponent): \(formatFileCount(totalFilesProcessed)) files (\(formatBytes(totalBytesProcessed))) • \(filesPerSecond)"
            
            // Calculate ETA using adaptive model
            if let eta = progressModel.getETA(processedFiles: totalFilesProcessed) {
                if eta > 120 {
                    let minutes = Int(eta / 60)
                    estimatedTimeRemaining = "~\(minutes) min remaining"
                } else if eta > 10 {
                    estimatedTimeRemaining = "~\(Int(eta)) sec remaining"
                } else {
                    estimatedTimeRemaining = "Almost done..."
                }
            } else {
                estimatedTimeRemaining = "Calculating..."
            }
            
            lastProgressUpdate = now
        }
    }
    
    private func formatRate(_ rate: Double) -> String {
        if rate >= 1000 {
            return String(format: "%.1fK files/sec", rate / 1000.0)
        } else if rate >= 1 {
            return String(format: "%.0f files/sec", rate)
        } else {
            return "< 1 file/sec"
        }
    }
    
    private func formatFileCount(_ count: Int) -> String {
        if count >= 1000000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        } else {
            return "\(count)"
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func calculatePercentages() {
        guard totalSize > 0 else { return }
        for i in rootItems.indices {
            rootItems[i].percentage = Double(rootItems[i].size) / Double(totalSize) * 100
        }
    }
    
    private func hasFullDiskAccess() -> Bool {
        // Test FDA by attempting to access TCC database and other protected locations
        let testPaths = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/private/var/db/dslocal/nodes/Default/users",
            "/System/Library/CoreServices"
        ]
        
        for testPath in testPaths {
            do {
                // For files, try to read attributes
                // For directories, try to list contents  
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: testPath, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        let _ = try FileManager.default.contentsOfDirectory(atPath: testPath)
                    } else {
                        let _ = try FileManager.default.attributesOfItem(atPath: testPath)
                    }
                    return true
                }
            } catch {
                continue
            }
        }
        
        return false
    }
    
    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
        scanProgress = ""
    }
    
    func scanExternalVolumes() async {
        await MainActor.run {
            self.externalVolumes = []
        }
        
        guard let volumeContents = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") else {
            return
        }
        
        var volumes: [FolderItem] = []
        
        for volume in volumeContents {
            let volumePath = "/Volumes/\(volume)"
            var isDirectory: ObjCBool = false
            
            if FileManager.default.fileExists(atPath: volumePath, isDirectory: &isDirectory),
               isDirectory.boolValue {
                
                // Skip system volumes and Time Machine volumes
                if shouldSkipVolume(named: volume) {
                    continue
                }
                
                // Get basic volume info
                let volumeURL = URL(fileURLWithPath: volumePath)
                
                do {
                    let resourceValues = try volumeURL.resourceValues(forKeys: [
                        .contentModificationDateKey,
                        .volumeTotalCapacityKey,
                        .volumeAvailableCapacityForImportantUsageKey,
                        .volumeIsRemovableKey,
                        .volumeIsEjectableKey,
                        .volumeIsInternalKey
                    ])
                    
                    let totalCapacity = Int64(resourceValues.volumeTotalCapacity ?? 0)
                    let availableCapacity = Int64(resourceValues.volumeAvailableCapacityForImportantUsage ?? 0)
                    let usedCapacity = totalCapacity - availableCapacity
                    
                    // Determine if this is an external drive
                    let isExternal = resourceValues.volumeIsRemovable == true || 
                                   resourceValues.volumeIsEjectable == true || 
                                   resourceValues.volumeIsInternal == false
                    
                    let volumeItem = FolderItem(
                        name: isExternal ? "\(volume) (External)" : volume,
                        path: volumePath,
                        size: usedCapacity,
                        itemCount: 0, // Will be calculated when scanned
                        lastModified: resourceValues.contentModificationDate ?? Date.distantPast,
                        isDirectory: true
                    )
                    
                    volumes.append(volumeItem)
                } catch {
                    // If we can't get volume info, still include it as external
                    let volumeItem = FolderItem(
                        name: "\(volume) (External)",
                        path: volumePath,
                        size: 0,
                        itemCount: 0,
                        lastModified: Date.distantPast,
                        isDirectory: true
                    )
                    volumes.append(volumeItem)
                }
            }
        }
        
        await MainActor.run {
            self.externalVolumes = volumes.sorted { $0.size > $1.size }
        }
    }
    
    // Skip Time Machine, system, and other volumes that shouldn't be scanned automatically
    private func shouldSkipVolume(named volume: String) -> Bool {
        let skipPatterns = [
            "Macintosh HD",              // Main system drive
            "com.apple.TimeMachine",     // Time Machine local snapshots
            "Time Machine Backups",      // Time Machine volumes
            ".timemachine",              // Time Machine hidden volumes
            "Preboot",                   // System preboot volume
            "Recovery",                  // Recovery volume
            "VM",                        // Virtual memory volume
            "Update",                    // System update volume
            "Data",                      // System data volume (if separate)
            "Install"                    // Installation volumes
        ]
        
        let volumeLower = volume.lowercased()
        
        for pattern in skipPatterns {
            if volumeLower.contains(pattern.lowercased()) {
                return true
            }
        }
        
        return false
    }
}