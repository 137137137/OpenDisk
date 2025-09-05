import Foundation
import Darwin

/// Result structure for progressive scanning updates
private struct ProgressiveScanResult {
    let items: [FolderItem]
    let directoryPath: String
    let isComplete: Bool
}

/// High-performance file scanner implementing all optimization techniques from the architecture plan
@MainActor
class OptimizedScanner: ObservableObject {
    
    // MARK: - Concurrency Configuration
    
    /// Optimal concurrency based on system capabilities
    private let maxConcurrentTasks: Int
    private let processorCount: Int
    
    // MARK: - Progress Tracking
    
    @Published var scanProgress: String = ""
    @Published var filesPerSecond: String = ""
    @Published var estimatedTimeRemaining: String = ""
    @Published var scanProgressPercentage: Double = 0.0
    
    // MARK: - Smart Caching with FSEvents
    
    private let smartCache = SmartDirectoryCache()
    private var isMonitoringEnabled = false
    
    
    // MARK: - Initialization
    
    init() {
        self.processorCount = ProcessInfo.processInfo.processorCount
        // More aggressive concurrency for I/O bound tasks - use 2x processor count
        self.maxConcurrentTasks = max(4, processorCount * 2)
        
        print("OptimizedScanner initialized with \(maxConcurrentTasks) concurrent tasks for \(processorCount) processors")
    }
    
    // MARK: - Smart Scanning with Caching and Progressive Loading
    
    /// Scan directory with intelligent caching, FSEvents monitoring, and progressive loading
    func scanDirectoryOptimized(
        _ path: String,
        enableMonitoring: Bool = true,
        progressHandler: @escaping (Double, String) -> Void = { _, _ in },
        progressiveResultHandler: @escaping ([FolderItem]) -> Void = { _ in }
    ) async -> [FolderItem] {
        
        // Check cache first
        let cachedItems = await MainActor.run { 
            return self.smartCache.getCachedFolderTree(for: path)
        }
        if let cachedItems = cachedItems {
            print("Using cached data for: \(path)")
            progressHandler(100.0, "Using cached data")
            progressiveResultHandler(cachedItems)
            return cachedItems
        }
        
        // Prevent concurrent scans of the same path
        let scanActive = await MainActor.run { 
            return self.smartCache.isScanActive(for: path)
        }
        if scanActive {
            print("Scan already active for: \(path)")
            return []
        }
        
        await MainActor.run { 
            self.smartCache.markScanActive(for: path) 
        }
        defer { 
            Task { [weak self] in
                await MainActor.run { 
                    self?.smartCache.markScanCompleted(for: path) 
                } 
            } 
        }
        
        // Start FSEvents monitoring if enabled
        if enableMonitoring && !isMonitoringEnabled {
            await startIntelligentMonitoring(for: [path])
        }
        
        // Perform optimized scan with progressive loading
        let items = await performOptimizedScanWithProgressiveLoading(
            path: path,
            progressHandler: progressHandler,
            progressiveResultHandler: progressiveResultHandler
        )
        
        // Cache results
        await MainActor.run { 
            self.smartCache.cacheFolderTree(items, for: path) 
        }
        
        return items
    }
    
    // MARK: - Progressive Loading Implementation
    
    private func performOptimizedScanWithProgressiveLoading(
        path: String,
        progressHandler: @escaping (Double, String) -> Void,
        progressiveResultHandler: @escaping ([FolderItem]) -> Void
    ) async -> [FolderItem] {
        
        let startTime = Date()
        progressHandler(0.0, "Starting progressive scan...")
        
        // First, quickly get immediate directory contents for immediate UI feedback
        if let immediateItems = await getImmediateContentsProgressive(path: path) {
            progressiveResultHandler(immediateItems.sorted())
            progressHandler(25.0, "Showing immediate contents...")
        }
        
        // Now perform the full optimized scan with progressive updates
        return await withTaskGroup(of: ProgressiveScanResult.self, returning: [FolderItem].self) { taskGroup in
            var allItems: [FolderItem] = []
            var progressiveItems: [FolderItem] = []
            let progressUpdateInterval: TimeInterval = 0.5 // Update every 0.5 seconds
            var lastProgressUpdate = Date()
            
            // Get immediate directory contents first
            guard let immediateContents = await getImmediateContents(path: path) else {
                return []
            }
            
            let (files, subdirectories) = separateFilesAndDirectories(immediateContents)
            
            // Add files immediately (they're already processed)
            allItems.append(contentsOf: files)
            progressiveItems.append(contentsOf: files)
            
            // Add subdirectories to allItems first (before scanning their contents)
            allItems.append(contentsOf: subdirectories)
            progressiveItems.append(contentsOf: subdirectories)
            
            let totalItemsToProcess = subdirectories.count
            var processedItems = 0
            
            // Process subdirectories progressively in batches
            let batchSize = min(maxConcurrentTasks, subdirectories.count)
            
            for batch in subdirectories.chunkedOptimized(into: batchSize) {
                // Process batch concurrently
                for directory in batch {
                    taskGroup.addTask {
                        let directoryItems = await self.scanSingleDirectoryRecursively(directory.path)
                        return ProgressiveScanResult(
                            items: directoryItems,
                            directoryPath: directory.path,
                            isComplete: true
                        )
                    }
                }
                
                // Collect results from this batch and provide progressive updates
                for await batchResult in taskGroup {
                    // Find the corresponding directory in allItems and update its size
                    if let dirIndex = allItems.firstIndex(where: { $0.path == batchResult.directoryPath && $0.isDirectory }) {
                        let childrenTotalSize = batchResult.items.reduce(0) { $0 + $1.size }
                        let updatedDirectory = FolderItem(
                            name: allItems[dirIndex].name,
                            path: allItems[dirIndex].path,
                            size: childrenTotalSize,
                            isDirectory: allItems[dirIndex].isDirectory,
                            itemCount: batchResult.items.count,
                            lastModified: allItems[dirIndex].lastModified
                        )
                        allItems[dirIndex] = updatedDirectory
                        
                        // Update in progressiveItems too if it exists there
                        if let progIndex = progressiveItems.firstIndex(where: { $0.path == batchResult.directoryPath && $0.isDirectory }) {
                            progressiveItems[progIndex] = updatedDirectory
                        }
                    }
                    processedItems += 1
                    
                    let progress = Double(processedItems) / Double(totalItemsToProcess) * 75.0 + 25.0 // 25-100%
                    let elapsed = Date().timeIntervalSince(startTime)
                    let rate = elapsed > 0 ? Double(allItems.count) / elapsed : 0
                    
                    // Update UI properties (already on MainActor)
                    self.scanProgressPercentage = progress
                    self.filesPerSecond = String(format: "%.0f items/sec", rate)
                    
                    if rate > 0 {
                        let remaining = Double(totalItemsToProcess - processedItems) / (rate / Double(allItems.count))
                        self.estimatedTimeRemaining = formatTimeInterval(remaining)
                    }
                    
                    progressHandler(progress, "Processed \(processedItems)/\(totalItemsToProcess) directories")
                    
                    // Progressive UI update at intervals
                    let now = Date()
                    if now.timeIntervalSince(lastProgressUpdate) >= progressUpdateInterval {
                        progressiveResultHandler(progressiveItems.sorted())
                        progressiveItems = [] // Clear for next batch
                        lastProgressUpdate = now
                    }
                }
            }
            
            // Final progressive update with any remaining items
            if !progressiveItems.isEmpty {
                progressiveResultHandler(allItems.sorted())
            }
            
            let elapsed = Date().timeIntervalSince(startTime)
            print("Progressive optimized scan completed in \(String(format: "%.2f", elapsed)) seconds")
            
            return allItems.sorted()
        }
    }
    
    private func getImmediateContentsProgressive(path: String) async -> [FolderItem]? {
        // Use a faster, simpler approach for immediate feedback
        return await Task.detached {
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: path)
                var items: [FolderItem] = []
                
                // Process only first 20-50 items for immediate feedback
                let quickScanCount = min(50, contents.count)
                let limitedContents = Array(contents.prefix(quickScanCount))
                
                for fileName in limitedContents {
                    let fullPath = path == "/" ? "/\(fileName)" : "\(path)/\(fileName)"
                    var isDirectory: ObjCBool = false
                    
                    guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
                        continue
                    }
                    
                    // Quick size estimation without detailed resource fetching
                    var size: Int64 = 0
                    if !isDirectory.boolValue {
                        do {
                            let attrs = try FileManager.default.attributesOfItem(atPath: fullPath)
                            size = attrs[.size] as? Int64 ?? 0
                        } catch {
                            size = 0
                        }
                    } else {
                        // For directories, use a fast size estimation for immediate feedback
                        size = await DiskAnalyzer.getDirectoryTotalSizeFast(path: fullPath)
                    }
                    
                    let item = FolderItem(
                        name: fileName,
                        path: fullPath,
                        size: size,
                        isDirectory: isDirectory.boolValue,
                        itemCount: 1,
                        lastModified: Date() // Use current time for immediate feedback
                    )
                    
                    items.append(item)
                }
                
                return items.sorted()
            } catch {
                return nil
            }
        }.value
    }
    
    // MARK: - Core Scanning Logic with All Optimizations
    
    private func performOptimizedScan(
        path: String,
        progressHandler: @escaping (Double, String) -> Void
    ) async -> [FolderItem] {
        
        let startTime = Date()
        
        progressHandler(0.0, "Initializing optimized scan...")
        
        // Use TaskGroup for structured concurrency as recommended
        let results = await withTaskGroup(of: [FolderItem].self, returning: [FolderItem].self) { taskGroup in
            var allItems: [FolderItem] = []
            
            // Get immediate directory contents first
            guard let immediateContents = await getImmediateContents(path: path) else {
                return []
            }
            
            let totalItemsToProcess = immediateContents.count
            var processedItems = 0
            
            // Process items in controlled batches to avoid overwhelming the system
            let batchSize = min(maxConcurrentTasks, immediateContents.count)
            
            for batch in immediateContents.chunkedOptimized(into: batchSize) {
                // Process batch concurrently
                for item in batch {
                    taskGroup.addTask {
                        return await self.processSingleItemOptimized(item, progressHandler: progressHandler)
                    }
                }
                
                // Collect results from this batch
                for await batchResults in taskGroup {
                    allItems.append(contentsOf: batchResults)
                    processedItems += batchResults.count
                    
                    let progress = Double(processedItems) / Double(totalItemsToProcess) * 100.0
                    let elapsed = Date().timeIntervalSince(startTime)
                    let rate = elapsed > 0 ? Double(processedItems) / elapsed : 0
                    
                    // Update UI properties (already on MainActor)
                    self.scanProgressPercentage = progress
                    self.filesPerSecond = String(format: "%.0f files/sec", rate)
                    
                    if rate > 0 {
                        let remaining = Double(totalItemsToProcess - processedItems) / rate
                        self.estimatedTimeRemaining = formatTimeInterval(remaining)
                    }
                    
                    progressHandler(progress, "Processed \(processedItems)/\(totalItemsToProcess) items")
                }
            }
            
            return allItems.sorted()
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("Optimized scan completed in \(String(format: "%.2f", elapsed)) seconds")
        
        return results
    }
    
    // MARK: - Optimized Single Item Processing
    
    private func processSingleItemOptimized(
        _ item: FolderItem,
        progressHandler: @escaping (Double, String) -> Void
    ) async -> [FolderItem] {
        
        // Simplified approach - use Task.detached directly without double-wrapping
        return await Task.detached { [item] in
            if item.isDirectory {
                // For directories, use the optimized bulk scanning if available
                return await self.scanDirectoryWithBulkOptimization(path: item.path)
            } else {
                // Return single file item
                return [item]
            }
        }.value
    }
    
    // MARK: - Parallel Bulk Optimization with URLResourceKeys
    
    private func scanDirectoryWithBulkOptimization(path: String) async -> [FolderItem] {
        return await Task.detached {
            // First get immediate directory contents
            guard let immediateContents = try? await self.getImmediateDirectoryContents(path: path) else {
                return []
            }
            
            let (files, subdirectories) = self.separateFilesAndDirectories(immediateContents)
            
            // Process files synchronously (they're fast)
            var allItems = files
            
            // Process subdirectories in parallel batches
            if !subdirectories.isEmpty {
                let parallelResults = await self.processDirectoriesInParallel(subdirectories, maxTasks: self.maxConcurrentTasks)
                allItems.append(contentsOf: parallelResults)
            }
            
            print("DEBUG: OptimizedScanner processed \(allItems.count) items for \(path)")
            return allItems.sorted()
        }.value
    }
    
    private nonisolated func processDirectoriesInParallel(_ directories: [FolderItem], maxTasks: Int) async -> [FolderItem] {
        let batchSize = min(maxTasks, directories.count)
        var allResults: [FolderItem] = []
        
        // Process directories in batches to avoid overwhelming the system
        for batch in directories.chunkedOptimized(into: batchSize) {
            let batchResults = await withTaskGroup(of: [FolderItem].self, returning: [FolderItem].self) { taskGroup in
                var results: [FolderItem] = []
                
                for directory in batch {
                    taskGroup.addTask {
                        await self.scanSingleDirectoryRecursively(directory.path)
                    }
                }
                
                for await batchResult in taskGroup {
                    results.append(contentsOf: batchResult)
                }
                
                return results
            }
            allResults.append(contentsOf: batchResults)
        }
        
        return allResults
    }
    
    private nonisolated func scanSingleDirectoryRecursively(_ path: String) async -> [FolderItem] {
        // Try syscall-based scanning first for maximum performance
        if let syscallResults = await trySyscallBasedScanning(path: path) {
            // Calculate directory sizes for syscall results
            return await calculateDirectorySizes(for: syscallResults)
        }
        
        // Fallback to FileManager approach
        let fallbackResults = await scanWithFileManagerFallback(path: path)
        // Calculate directory sizes for fallback results too
        return await calculateDirectorySizes(for: fallbackResults)
    }
    
    private nonisolated func calculateDirectorySizes(for items: [FolderItem]) async -> [FolderItem] {
        // Create a new array with properly calculated directory sizes
        var updatedItems: [FolderItem] = []
        
        for item in items {
            if item.isDirectory && item.size == 0 {
                // Calculate the actual directory size
                let actualSize = await DiskAnalyzer.getDirectoryTotalSizeFast(path: item.path)
                let updatedItem = FolderItem(
                    name: item.name,
                    path: item.path,
                    size: actualSize,
                    isDirectory: item.isDirectory,
                    itemCount: item.itemCount,
                    lastModified: item.lastModified
                )
                updatedItems.append(updatedItem)
            } else {
                updatedItems.append(item)
            }
        }
        
        return updatedItems
    }
    
    // MARK: - Syscall-based scanning with large buffers
    
    private nonisolated func trySyscallBasedScanning(path: String) async -> [FolderItem]? {
        return await Task.detached {
            do {
                // First try memory-mapped scanning for potentially very large directories
                if let mmapResults = try? await self.scanWithMemoryMapping(path: path) {
                    return mmapResults
                }
                
                // Fall back to regular syscalls
                return try await self.scanDirectoryWithSyscalls(path: path)
            } catch {
                print("Syscall scanning failed for \(path): \(error), falling back to FileManager")
                return nil
            }
        }.value
    }
    
    // MARK: - Memory-mapped scanning for large directories
    
    private nonisolated func scanWithMemoryMapping(path: String) async throws -> [FolderItem]? {
        let dirfd = Darwin.open(path, O_RDONLY)
        guard dirfd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
        defer { Darwin.close(dirfd) }
        
        // Get directory size to determine if memory mapping is worthwhile
        var statBuf = stat()
        guard Darwin.fstat(dirfd, &statBuf) == 0 else {
            return nil // Can't stat, skip memory mapping
        }
        
        // Only use memory mapping for directories that might benefit from it
        // We'll use a heuristic: if the directory has a lot of potential entries
        let directorySize = statBuf.st_size
        guard directorySize > 8192 else { // Less than 8KB, probably not worth memory mapping
            return nil
        }
        
        // For directories, we can't directly memory map the directory entries
        // Instead, we'll use a larger buffer with mmap for the syscall buffer
        let bufferSize = max(131072, Int(directorySize * 2)) // At least 128KB
        
        // Map anonymous memory for our buffer
        guard let mappedBuffer = mmap(
            nil,
            bufferSize,
            PROT_READ | PROT_WRITE,
            MAP_ANON | MAP_PRIVATE,
            -1,
            0
        ) else {
            return nil
        }
        
        if mappedBuffer == MAP_FAILED {
            return nil
        }
        
        defer {
            munmap(mappedBuffer, bufferSize)
        }
        
        // Use the memory-mapped buffer for getattrlistbulk operations
        return try await scanWithMemoryMappedBuffer(
            dirfd: dirfd,
            buffer: mappedBuffer,
            bufferSize: bufferSize,
            path: path
        )
    }
    
    private nonisolated func scanWithMemoryMappedBuffer(
        dirfd: Int32,
        buffer: UnsafeMutableRawPointer,
        bufferSize: Int,
        path: String
    ) async throws -> [FolderItem] {
        var items: [FolderItem] = []
        let seenFileIDs = ShardedFileIDSet(shardCount: 32) // More shards for potentially larger directories
        
        // Setup attrlist for getattrlistbulk
        var attrList = attrlist()
        attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID)
        attrList.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE | ATTR_FILE_TOTALSIZE)
        attrList.dirattr = 0
        
        var iterationCount = 0
        let maxIterations = 2000 // Higher limit for large directories
        
        repeat {
            iterationCount += 1
            if iterationCount > maxIterations {
                print("Warning: Maximum iteration count reached for large directory \(path)")
                break
            }
            
            let result = getattrlistbulk(
                dirfd,
                &attrList,
                buffer,
                bufferSize,
                0 // No options - get all entries
            )
            
            guard result > 0 else {
                if result == 0 {
                    // No more entries
                    break
                } else {
                    // Error occurred
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
                }
            }
            
            // Process the memory-mapped buffer in larger batches
            autoreleasepool {
                var offset = 0
                var entriesProcessed = 0
                let batchSize = 1000 // Process up to 1000 entries per autoreleasepool for large directories
                
                while offset < result && entriesProcessed < batchSize {
                    let entryLength = buffer.load(fromByteOffset: offset, as: UInt32.self)
                    
                    guard entryLength > 8 && offset + Int(entryLength) <= result else {
                        break
                    }
                    
                    if let folderItem = self.parseMemoryMappedEntry(
                        buffer: buffer,
                        offset: offset,
                        basePath: path,
                        seenFileIDs: seenFileIDs
                    ) {
                        items.append(folderItem)
                    }
                    
                    offset += Int(entryLength)
                    entriesProcessed += 1
                }
            }
        } while true
        
        return items.sorted()
    }
    
    private nonisolated func parseMemoryMappedEntry(
        buffer: UnsafeMutableRawPointer,
        offset: Int,
        basePath: String,
        seenFileIDs: ShardedFileIDSet
    ) -> FolderItem? {
        let entryLength = buffer.load(fromByteOffset: offset, as: UInt32.self)
        
        // Validate entry length
        guard entryLength > 8 else { return nil }
        
        var currentOffset = offset + 4 // Skip entry length
        
        // Parse object type
        let objType = buffer.load(fromByteOffset: currentOffset, as: UInt32.self)
        currentOffset += 4
        
        let isDirectory = vtype(objType) == VREG ? false : (vtype(objType) == VDIR ? true : false)
        
        // Parse file ID for deduplication
        let fileID = buffer.load(fromByteOffset: currentOffset, as: UInt64.self)
        currentOffset += 8
        
        // Skip if we've seen this file ID (hard link deduplication)
        let fileIDData = withUnsafeBytes(of: fileID) { Data($0) }
        if !seenFileIDs.insert(fileIDData) {
            return nil // Skip duplicate
        }
        
        // Parse modification time
        let modTime = buffer.load(fromByteOffset: currentOffset, as: timespec.self)
        currentOffset += MemoryLayout<timespec>.size
        
        let modificationDate = Date(timeIntervalSince1970: TimeInterval(modTime.tv_sec))
        
        // Parse allocated size (for files only, directories will be calculated later)
        var size: Int64 = 0
        if !isDirectory {
            size = buffer.load(fromByteOffset: currentOffset, as: Int64.self)
        }
        currentOffset += 8
        
        // Parse name length and name
        let nameLength = buffer.load(fromByteOffset: currentOffset, as: UInt32.self)
        currentOffset += 4
        
        guard nameLength > 0 && nameLength < 1024 else { return nil } // Increased sanity check for large directories
        
        // Extract name bytes from memory-mapped buffer
        let nameBuffer = buffer.advanced(by: currentOffset).assumingMemoryBound(to: UInt8.self)
        guard let name = String(bytes: UnsafeBufferPointer(start: nameBuffer, count: Int(nameLength)), encoding: .utf8) else {
            return nil
        }
        
        // Include all files (including hidden files starting with ".")
        // No filtering based on filename
        
        let fullPath = basePath == "/" ? "/\(name)" : "\(basePath)/\(name)"
        
        // For directories, we can't calculate size in memory-mapped context
        // This will need to be done in a separate pass
        if isDirectory {
            size = 0
        }
        
        return FolderItem(
            name: name,
            path: fullPath,
            size: size,
            isDirectory: isDirectory,
            itemCount: isDirectory ? 0 : 1,
            lastModified: modificationDate
        )
    }
    
    private nonisolated func scanDirectoryWithSyscalls(path: String) async throws -> [FolderItem] {
        let dirfd = Darwin.open(path, O_RDONLY)
        guard dirfd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
        defer { Darwin.close(dirfd) }
        
        // Large buffer for bulk operations - 64KB should handle ~1000-2000 entries
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var items: [FolderItem] = []
        let seenFileIDs = ShardedFileIDSet(shardCount: 16)
        
        // Setup attrlist for getattrlistbulk
        var attrList = attrlist()
        attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID)
        attrList.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE | ATTR_FILE_TOTALSIZE)
        attrList.dirattr = 0
        
        var iterationCount = 0
        let maxIterations = 1000 // Prevent infinite loops
        
        repeat {
            iterationCount += 1
            if iterationCount > maxIterations {
                print("Warning: Maximum iteration count reached for \(path)")
                break
            }
            
            let result = buffer.withUnsafeMutableBytes { bufferPtr in
                getattrlistbulk(
                    dirfd,
                    &attrList,
                    bufferPtr.baseAddress,
                    bufferSize,
                    0 // No options - get all entries
                )
            }
            
            guard result > 0 else {
                if result == 0 {
                    // No more entries
                    break
                } else {
                    // Error occurred
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
                }
            }
            
            // Process the buffer in batches for better memory management
            autoreleasepool {
                var offset = 0
                var entriesProcessed = 0
                
                while offset < result && entriesProcessed < 500 { // Process max 500 entries per autoreleasepool
                    let entryLength = buffer.withUnsafeBytes { bytes in
                        bytes.load(fromByteOffset: offset, as: UInt32.self)
                    }
                    
                    guard entryLength > 8 && offset + Int(entryLength) <= result else {
                        break
                    }
                    
                    if let folderItem = self.parseSyscallEntry(buffer: buffer, offset: offset, basePath: path, seenFileIDs: seenFileIDs) {
                        items.append(folderItem)
                    }
                    
                    offset += Int(entryLength)
                    entriesProcessed += 1
                }
            }
        } while true
        
        return items.sorted()
    }
    
    private nonisolated func parseSyscallEntry(buffer: [UInt8], offset: Int, basePath: String, seenFileIDs: ShardedFileIDSet) -> FolderItem? {
        let entryLength = buffer.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: offset, as: UInt32.self)
        }
        
        // Validate entry length
        guard entryLength > 8 else { return nil }
        
        var currentOffset = offset + 4 // Skip entry length
        
        // Parse object type
        let objType = buffer.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: currentOffset, as: UInt32.self)
        }
        currentOffset += 4
        
        let isDirectory = vtype(objType) == VREG ? false : (vtype(objType) == VDIR ? true : false)
        
        // Parse file ID for deduplication
        let fileID = buffer.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: currentOffset, as: UInt64.self)
        }
        currentOffset += 8
        
        // Skip if we've seen this file ID (hard link deduplication)
        let fileIDData = withUnsafeBytes(of: fileID) { Data($0) }
        if !seenFileIDs.insert(fileIDData) {
            return nil // Skip duplicate
        }
        
        // Parse modification time
        let modTime = buffer.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: currentOffset, as: timespec.self)
        }
        currentOffset += MemoryLayout<timespec>.size
        
        let modificationDate = Date(timeIntervalSince1970: TimeInterval(modTime.tv_sec))
        
        // Parse allocated size (for files only, directories will be calculated later)
        var size: Int64 = 0
        if !isDirectory {
            size = buffer.withUnsafeBytes { bytes in
                bytes.load(fromByteOffset: currentOffset, as: Int64.self)
            }
        }
        currentOffset += 8
        
        // Parse name length and name
        let nameLength = buffer.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: currentOffset, as: UInt32.self)
        }
        currentOffset += 4
        
        guard nameLength > 0 && nameLength < 256 else { return nil } // Sanity check
        
        let nameBytes = Array(buffer[currentOffset..<currentOffset + Int(nameLength)])
        guard let name = String(bytes: nameBytes, encoding: .utf8) else { return nil }
        
        // Include all files (including hidden files starting with ".")
        // No filtering based on filename
        
        let fullPath = basePath == "/" ? "/\(name)" : "\(basePath)/\(name)"
        
        // For directories, we can't calculate size in syscall context
        // This will need to be done in a separate pass
        if isDirectory {
            size = 0
        }
        
        return FolderItem(
            name: name,
            path: fullPath,
            size: size,
            isDirectory: isDirectory,
            itemCount: isDirectory ? 0 : 1,
            lastModified: modificationDate
        )
    }
    
    // MARK: - FileManager fallback with optimizations
    
    private nonisolated func scanWithFileManagerFallback(path: String) async -> [FolderItem] {
        // Comprehensive URLResourceKeys for maximum efficiency
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .fileResourceIdentifierKey,  // For hard-link deduplication
            .volumeIdentifierKey,         // For volume boundary detection
            .fileResourceTypeKey
        ]
        
        var items: [FolderItem] = []
        let seenFileIDs = ShardedFileIDSet(shardCount: 16)
        
        // Use FileManager enumerator with prefetched keys for maximum efficiency
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants],
            errorHandler: { (url, error) in
                // Only log non-permission errors to reduce noise
                if !error.localizedDescription.contains("permission") && !error.localizedDescription.contains("Permission denied") {
                    print("Enumeration error for \(url): \(error)")
                }
                return true // Continue enumeration
            }
        ) else {
            return []
        }
        
        // Process all items with larger autoreleasepool batches for better performance
        var itemCount = 0
        var batchItems: [FolderItem] = []
        let autoreleaseBatchSize = 100 // Process 100 items per autoreleasepool
        
        while let item = enumerator.nextObject() {
            guard let url = item as? URL else { continue }
            itemCount += 1
            
            do {
                let resourceValues = try url.resourceValues(forKeys: Set(resourceKeys))
                
                // Skip symbolic links to avoid cycles
                if resourceValues.isSymbolicLink == true { continue }
                
                let isDirectory = resourceValues.isDirectory ?? false
                let isRegular = resourceValues.isRegularFile ?? false
                
                var size: Int64 = 0
                
                if isRegular {
                    // Deduplicate hard links using file resource identifier
                    if let fileID = resourceValues.fileResourceIdentifier as? Data {
                        if !seenFileIDs.insert(fileID) {
                            continue // Skip duplicate hard link
                        }
                    }
                    
                    // Use allocated size for accurate disk usage
                    if let totalAllocated = resourceValues.totalFileAllocatedSize {
                        size = Int64(totalAllocated)
                    } else if let allocated = resourceValues.fileAllocatedSize {
                        size = Int64(allocated)
                    } else if let logical = resourceValues.fileSize {
                        size = Int64(logical)
                    }
                } else if isDirectory {
                    // For directories, we'll calculate size outside this loop
                    size = 0
                }
                
                let modificationDate = resourceValues.contentModificationDate ?? 
                                     resourceValues.creationDate ?? 
                                     Date()
                
                let folderItem = FolderItem(
                    name: url.lastPathComponent,
                    path: url.path,
                    size: size,
                    isDirectory: isDirectory,
                    itemCount: isDirectory ? 0 : 1,
                    lastModified: modificationDate
                )
                
                batchItems.append(folderItem)
                
                // Periodically use autoreleasepool for batches
                if batchItems.count >= autoreleaseBatchSize {
                    autoreleasepool {
                        items.append(contentsOf: batchItems)
                        batchItems.removeAll(keepingCapacity: true)
                    }
                }
                
            } catch {
                // Skip items that can't be accessed
                continue
            }
        }
        
        // Add remaining items
        if !batchItems.isEmpty {
            autoreleasepool {
                items.append(contentsOf: batchItems)
            }
        }
        
        // Calculate directory sizes for any directories that have size 0
        var finalItems: [FolderItem] = []
        for item in items {
            if item.isDirectory && item.size == 0 {
                let actualSize = await DiskAnalyzer.getDirectoryTotalSizeFast(path: item.path)
                let updatedItem = FolderItem(
                    name: item.name,
                    path: item.path,
                    size: actualSize,
                    isDirectory: item.isDirectory,
                    itemCount: item.itemCount,
                    lastModified: item.lastModified
                )
                finalItems.append(updatedItem)
            } else {
                finalItems.append(item)
            }
        }
        
        return finalItems
    }
    
    private nonisolated func getImmediateDirectoryContents(path: String) async throws -> [FolderItem] {
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]
        
        let contents = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants]
        )
        
        var items: [FolderItem] = []
        let seenFileIDs = ShardedFileIDSet(shardCount: 16)
        
        for url in contents {
            do {
                let resourceValues = try url.resourceValues(forKeys: Set(resourceKeys))
                
                if resourceValues.isSymbolicLink == true { continue }
                
                let isDirectory = resourceValues.isDirectory ?? false
                var size: Int64 = 0
                
                autoreleasepool {
                    if !isDirectory {
                        // Handle hard link deduplication
                        if let fileID = resourceValues.fileResourceIdentifier as? Data {
                            if !seenFileIDs.insert(fileID) { return }
                        }
                        
                        size = Int64(resourceValues.totalFileAllocatedSize ?? 
                                   resourceValues.fileAllocatedSize ?? 0)
                    }
                }
                
                // For directories, calculate the actual size (outside autoreleasepool for async)
                if isDirectory {
                    size = await DiskAnalyzer.getDirectoryTotalSizeFast(path: url.path)
                }
                
                let item = FolderItem(
                    name: url.lastPathComponent,
                    path: url.path,
                    size: size,
                    isDirectory: isDirectory,
                    itemCount: 1,
                    lastModified: resourceValues.contentModificationDate ?? Date()
                )
                
                items.append(item)
                
            } catch {
                continue
            }
        }
        
        return items.sorted()
    }
    
    private nonisolated func separateFilesAndDirectories(_ items: [FolderItem]) -> (files: [FolderItem], directories: [FolderItem]) {
        var files: [FolderItem] = []
        var directories: [FolderItem] = []
        
        for item in items {
            if item.isDirectory {
                directories.append(item)
            } else {
                files.append(item)
            }
        }
        
        return (files, directories)
    }
    
    // MARK: - Immediate Contents with Optimization
    
    private func getImmediateContents(path: String) async -> [FolderItem]? {
        return await Task.detached {
            do {
                let resourceKeys: [URLResourceKey] = [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey,
                    .contentModificationDateKey,
                    .fileResourceIdentifierKey
                ]
                
                let contents = try FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: path),
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsPackageDescendants]
                )
                
                var items: [FolderItem] = []
                let seenFileIDs = ShardedFileIDSet(shardCount: 16)
                
                for url in contents {
                    autoreleasepool {
                        do {
                            let resourceValues = try url.resourceValues(forKeys: Set(resourceKeys))
                            
                            if resourceValues.isSymbolicLink == true { return }
                            
                            let isDirectory = resourceValues.isDirectory ?? false
                            var size: Int64 = 0
                            
                            if !isDirectory {
                                // Handle hard link deduplication
                                if let fileID = resourceValues.fileResourceIdentifier as? Data {
                                    if !seenFileIDs.insert(fileID) { return }
                                }
                                
                                size = Int64(resourceValues.totalFileAllocatedSize ?? 
                                           resourceValues.fileAllocatedSize ?? 0)
                            }
                            
                            let item = FolderItem(
                                name: url.lastPathComponent,
                                path: url.path,
                                size: size,
                                isDirectory: isDirectory,
                                itemCount: 1,
                                lastModified: resourceValues.contentModificationDate ?? Date()
                            )
                            
                            items.append(item)
                            
                        } catch {
                            return
                        }
                    }
                }
                
                return items.sorted()
                
            } catch {
                print("Error getting immediate contents for \(path): \(error)")
                return nil
            }
        }.value
    }
    
    // MARK: - Smart Monitoring
    
    private func startIntelligentMonitoring(for paths: [String]) async {
        await MainActor.run {
            self.smartCache.startSmartMonitoring(for: paths) { invalidatedPath in
                print("Cache automatically invalidated for: \(invalidatedPath)")
                // Could trigger UI updates or partial rescans here
            }
            self.isMonitoringEnabled = true
        }
    }
    
    
    // MARK: - Cleanup
    
    func stopAllMonitoring() {
        smartCache.stopMonitoring()
    }
    
    func clearAllCaches() {
        smartCache.clearAllCaches()
    }
    
    deinit {
        // For deinit, we need to handle this carefully since we can't call async methods
        // The cache will be cleaned up automatically when the instance is deallocated
    }
}

// MARK: - Helper Extensions

private extension Array {
    func chunkedOptimized(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

private func formatTimeInterval(_ interval: TimeInterval) -> String {
    if interval < 60 {
        return String(format: "%.0fs", interval)
    } else if interval < 3600 {
        return String(format: "%.0fm %.0fs", interval / 60, interval.truncatingRemainder(dividingBy: 60))
    } else {
        let hours = Int(interval / 3600)
        let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
        return "\(hours)h \(minutes)m"
    }
}

// MARK: - Advanced Memory Management

// asyncAutoreleasePool function moved to SharedTypes.swift