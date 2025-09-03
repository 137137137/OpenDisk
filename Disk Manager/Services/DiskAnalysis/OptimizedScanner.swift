import Foundation
import Darwin
import MachO

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
    
    // MARK: - Memory Management
    
    private let memoryPressureThreshold: Int64 = 500 * 1024 * 1024 // 500MB
    private var currentMemoryUsage: Int64 = 0
    
    // MARK: - Initialization
    
    init() {
        self.processorCount = ProcessInfo.processInfo.processorCount
        // Use 4-8 concurrent tasks as recommended, limited by CPU cores
        self.maxConcurrentTasks = min(max(4, processorCount), 8)
        
        print("OptimizedScanner initialized with \(maxConcurrentTasks) concurrent tasks")
    }
    
    // MARK: - Smart Scanning with Caching
    
    /// Scan directory with intelligent caching and FSEvents monitoring
    func scanDirectoryOptimized(
        _ path: String,
        enableMonitoring: Bool = true,
        progressHandler: @escaping (Double, String) -> Void = { _, _ in }
    ) async -> [FolderItem] {
        
        // Check cache first
        if let cachedItems = smartCache.getCachedFolderTree(for: path) {
            print("Using cached data for: \(path)")
            progressHandler(100.0, "Using cached data")
            return cachedItems
        }
        
        // Prevent concurrent scans of the same path
        if smartCache.isScanActive(for: path) {
            print("Scan already active for: \(path)")
            return []
        }
        
        smartCache.markScanActive(for: path)
        defer { smartCache.markScanCompleted(for: path) }
        
        // Start FSEvents monitoring if enabled
        if enableMonitoring && !isMonitoringEnabled {
            await startIntelligentMonitoring(for: [path])
        }
        
        // Perform optimized scan
        let items = await performOptimizedScan(
            path: path,
            progressHandler: progressHandler
        )
        
        // Cache results
        smartCache.cacheFolderTree(items, for: path)
        
        return items
    }
    
    // MARK: - Core Scanning Logic with All Optimizations
    
    private func performOptimizedScan(
        path: String,
        progressHandler: @escaping (Double, String) -> Void
    ) async -> [FolderItem] {
        
        let startTime = Date()
        let totalFilesProcessed = 0
        _ = totalFilesProcessed // Suppress unused warning
        
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
                    let rate = elapsed > 0 ? Double(totalFilesProcessed) / elapsed : 0
                    
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
        
        return await asyncAutoreleasePool { () -> [FolderItem] in
            // Memory management - use autoreleasepool for each item as recommended
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
    }
    
    // MARK: - Bulk Optimization with URLResourceKeys
    
    private func scanDirectoryWithBulkOptimization(path: String) async -> [FolderItem] {
        return await Task.detached {
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
            
            do {
                // Use FileManager enumerator with prefetched keys for maximum efficiency
                guard let enumerator = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: path),
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { (url, error) in
                        print("Enumeration error for \(url): \(error)")
                        return true // Continue enumeration
                    }
                ) else {
                    return []
                }
                
                // Process all items with autoreleasepool for memory management
                while let item = enumerator.nextObject() {
                    guard let url = item as? URL else { continue }
                    autoreleasepool {
                        do {
                            let resourceValues = try url.resourceValues(forKeys: Set(resourceKeys))
                            
                            // Skip symbolic links to avoid cycles
                            if resourceValues.isSymbolicLink == true { return }
                            
                            let isDirectory = resourceValues.isDirectory ?? false
                            let isRegular = resourceValues.isRegularFile ?? false
                            
                            var size: Int64 = 0
                            
                            if isRegular {
                                // Deduplicate hard links using file resource identifier
                                if let fileID = resourceValues.fileResourceIdentifier as? Data {
                                    if !seenFileIDs.insert(fileID) {
                                        return // Skip duplicate hard link
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
                                // For directories, we'll calculate size recursively if needed
                                size = 0
                            }
                            
                            let modificationDate = resourceValues.contentModificationDate ?? 
                                                 resourceValues.creationDate ?? 
                                                 Date()
                            
                            let item = FolderItem(
                                name: url.lastPathComponent,
                                path: url.path,
                                size: size,
                                isDirectory: isDirectory,
                                itemCount: isDirectory ? 0 : 1,
                                lastModified: modificationDate
                            )
                            
                            items.append(item)
                            
                        } catch {
                            // Skip items that can't be accessed
                            return
                        }
                    }
                }
                
            } catch {
                print("Error scanning directory \(path): \(error)")
                return []
            }
            
            return items.sorted()
        }.value
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
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
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
        await smartCache.startSmartMonitoring(for: paths) { invalidatedPath in
            print("Cache automatically invalidated for: \(invalidatedPath)")
            // Could trigger UI updates or partial rescans here
        }
        isMonitoringEnabled = true
    }
    
    // MARK: - Memory Management
    
    private func checkMemoryPressure() -> Bool {
        let usage = getMemoryUsage()
        return usage > memoryPressureThreshold
    }
    
    private func getMemoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if result == KERN_SUCCESS {
            return Int64(info.resident_size)
        } else {
            return 0
        }
    }
    
    // MARK: - Cleanup
    
    nonisolated func stopAllMonitoring() {
        smartCache.stopMonitoring()
        // isMonitoringEnabled = false // Cannot modify MainActor property from nonisolated context
    }
    
    func clearAllCaches() {
        smartCache.clearAllCaches()
    }
    
    deinit {
        stopAllMonitoring()
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