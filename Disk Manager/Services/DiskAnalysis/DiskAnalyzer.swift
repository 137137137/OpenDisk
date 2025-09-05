import Foundation
import Darwin

// Thread-safe counter for cumulative progress tracking
actor CumulativeCounter {
    private var value: Int64 = 0
    
    func reset() {
        value = 0
    }
    
    func add(_ amount: Int64) {
        value += amount
    }
    
    func getValue() -> Int64 {
        return value
    }
}

@MainActor
class DiskAnalyzer: ObservableObject {
    @Published var rootItems: [FolderItem] = []
    @Published var isScanning: Bool = false
    @Published var scanProgress: String = ""
    @Published var scanProgressPercentage: Double = 0.0
    @Published var estimatedTimeRemaining: String = ""
    @Published var totalSize: Int64 = 0
    @Published var currentScanPath: String = ""
    @Published var filesPerSecond: String = ""
    
    // Track what path the current rootItems represent
    private var currentRootItemsPath: String = ""
    
    // Per-directory progress model
    @Published var currentDirTotalBytes: Int64 = 0
    @Published var currentDirScannedBytes: Int64 = 0 
    @Published var currentDirPercent: Double = 0.0
    
    // Whole-disk progress model
    @Published var totalDiskBytes: Int64 = 0
    @Published var totalDiskScannedBytes: Int64 = 0
    @Published var overallProgressPercentage: Double = 0.0
    
    // Real-time cumulative progress tracking (actor for thread safety)
    private let cumulativeCounter = CumulativeCounter()
    
    // Legacy properties (keeping for backward compatibility)
    @Published var scannedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var externalVolumes: [FolderItem] = []
    
    private var scanTask: Task<Void, Never>?
    private var scanStartTime: Date?
    private var totalFilesProcessed: Int = 0
    private var totalBytesProcessed: Int64 = 0
    private var progressModel = RateModel()
    private var lastProgressUpdate: Date = Date()
    private var seenFileIDs = ShardedFileIDSet(shardCount: 16)
    private let firmlinkResolver = FirmlinkResolver()
    
    // NEW: Optimized scanner and monitoring
    private let optimizedScanner = OptimizedScanner()
    private let fileSystemMonitor = FileSystemMonitor()
    private let smartCache = SmartDirectoryCache()
    
    // Complete folder tree for instant navigation
    private var folderTree: [String: [FolderItem]] = [:]
    
    // Pre-calculated directory sizes for instant progress bars
    private var sizeCache: [String: Int64] = [:]
    private var sizePrecalculationTasks: [String: Task<Int64, Never>] = [:]
    
    
    // Navigate to a path using pre-calculated data or scan if needed
    // Returns true if data was loaded (either from cache or fresh scan), false if scan failed
    func navigateToPath(_ path: String) -> Bool {
        print("DEBUG: navigateToPath called for: \(path)")
        
        // Check if we already have data loaded for this exact path
        if path == currentRootItemsPath && !rootItems.isEmpty && !isScanning {
            print("DEBUG: Already showing data for \(path)")
            calculatePercentages()
            return true
        }
        
        // Check folder tree cache
        if let cachedItems = folderTree[path], !cachedItems.isEmpty {
            print("DEBUG: Found cached data for \(path) with \(cachedItems.count) items")
            
            // Use the cached data directly - trust that it's complete from the initial scan
            rootItems = cachedItems
            currentRootItemsPath = path
            totalSize = cachedItems.reduce(0) { $0 + $1.size }
            calculatePercentages()
            return true
        }
        
        print("DEBUG: No cached data for \(path) - performing deep scan")
        
        // No cached data - perform a full recursive scan
        Task { @MainActor in
            let scannedItems = await scanDirectoryRecursive(path)
            
            if !scannedItems.isEmpty {
                print("DEBUG: Deep scan complete for \(path) with \(scannedItems.count) items")
                
                // Cache the results
                folderTree[path] = scannedItems
                
                // Also cache all subdirectory contents from the scan
                for item in scannedItems where item.isDirectory {
                    if !item.children.isEmpty {
                        folderTree[item.path] = item.children
                    }
                }
                
                // Update UI
                rootItems = scannedItems
                currentRootItemsPath = path
                totalSize = scannedItems.reduce(0) { $0 + $1.size }
                calculatePercentages()
            }
        }
        
        return true
    }
    
    func scanDirectory(_ path: String) async {
        scanTask?.cancel()
        
        // Stop any existing monitoring
        fileSystemMonitor.stopMonitoring()
        
        isScanning = true
        scanProgress = "Preparing to scan..."
        rootItems = []
        currentRootItemsPath = ""
        scanProgressPercentage = 0.0
        estimatedTimeRemaining = ""
        totalFilesProcessed = 0
        totalBytesProcessed = 0
        scanStartTime = Date()
        lastProgressUpdate = Date()
        currentScanPath = ""
        filesPerSecond = ""
        scannedBytes = 0
        totalBytes = 0
        totalDiskScannedBytes = 0
        await cumulativeCounter.reset()
        overallProgressPercentage = 0.0
        
        // Get total disk size for overall progress
        if path == "/" {
            totalDiskBytes = getTotalDiskSize(path: path)
        } else {
            totalDiskBytes = 0 // For non-root scans, don't show overall progress
        }
        
        // Initialize fresh progress model with better estimates for disk scanning
        progressModel = RateModel()
        
        // Improve initial estimate based on scan type
        if path == "/" {
            // Full disk scan - typically 500K to 2M files on macOS systems
            progressModel.estTotalFiles = 750_000
        } else {
            // Directory scan - start with smaller estimate
            progressModel.estTotalFiles = 50_000
        }
        
        // For root directory scan, request full disk access
        var scanPath = firmlinkResolver.canonicalize(path)
        
        if path == "/" {
            if !hasFullDiskAccess() {
                // Guide user to grant full disk access
                scanProgress = "Full Disk Access required. Please grant in System Settings > Privacy & Security > Full Disk Access > Add your app"
                isScanning = false
                return
            }
            scanPath = "/"
        }
        
        // Reset dedupe set for this scan
        seenFileIDs = ShardedFileIDSet(shardCount: 16)
        
        scanTask = Task { [weak self] in
            guard let self = self else { return }
            
            // Create local copies of captured variables to avoid concurrency issues
            let pathToScan = scanPath
            
            // Try optimized scanner first for better performance
            if pathToScan != "/" {
                let optimizedItems = await self.optimizedScanner.scanDirectoryOptimized(
                    pathToScan,
                    enableMonitoring: true
                ) { progress, message in
                    Task { @MainActor in
                        self.scanProgressPercentage = progress
                        self.scanProgress = message
                    }
                }
                
                if !optimizedItems.isEmpty {
                    await MainActor.run {
                        self.rootItems = optimizedItems.sorted()
                        self.currentRootItemsPath = path
                        // Cache the optimized scan results for navigation
                        self.folderTree[path] = optimizedItems.sorted()
                        self.totalSize = optimizedItems.reduce(0) { $0 + $1.size }
                        self.calculatePercentages()
                        
                        // Cache the folder tree for navigation
                        
                        self.isScanning = false
                        self.scanProgress = "Scan complete (optimized)"
                        self.scanProgressPercentage = 100.0
                        self.estimatedTimeRemaining = ""
                        print("DEBUG: Cached optimized scan results with \(optimizedItems.count) items for \(path)")
                    }
                    
                    // Start FSEvents monitoring for real-time updates
                    await self.startFileSystemMonitoring(for: pathToScan)
                    return
                }
            }
            
            // Scan external volumes in parallel
            async let volumesScan: Void = self.scanExternalVolumes()
            async let diskScan: [FolderItem] = self.performScanWithProgress(path: pathToScan)
            
            let items = await diskScan
            await volumesScan
            
            let sortedItems = items.sorted()
            
            await MainActor.run {
                self.rootItems = sortedItems
                self.currentRootItemsPath = path
                // Cache the root scan results for navigation
                self.folderTree[path] = sortedItems
                self.totalSize = sortedItems.reduce(0) { $0 + $1.size }
                self.calculatePercentages()
                self.isScanning = false
                self.scanProgress = "Scan complete"
                self.scanProgressPercentage = 100.0
                self.estimatedTimeRemaining = ""
                print("DEBUG: Cached root scan results with \(sortedItems.count) items for \(path)")
            }
        }
    }
    
    private func calculatePercentages() {
        guard totalSize > 0 else { return }
        
        for i in rootItems.indices {
            rootItems[i].percentage = Double(rootItems[i].size) / Double(totalSize) * 100.0
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
            // For other directories, use recursive scan for consistency
            await MainActor.run {
                self.scanProgress = "Scanning directory recursively..."
            }
            return await scanDirectoryRecursive(path)
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
            self.seenFileIDs = ShardedFileIDSet(shardCount: 16)
        }
        
        // Enumerate accessible top-level directories with better error handling
        return await scanRootDirectoriesSafely()
    }
    
    private func scanRootDirectoriesSafely() async -> [FolderItem] {
        // Get accessible directories using Task.detached
        let accessibleDirs = await Task.detached {
            do {
                let rootContents = try FileManager.default.contentsOfDirectory(atPath: "/")
                var accessible: [String] = []
                
                // Check which directories are actually accessible
                for item in rootContents {
                    let fullPath = "/" + item
                    var isDirectory: ObjCBool = false
                    
                    if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) && 
                       isDirectory.boolValue &&
                       FileManager.default.isReadableFile(atPath: fullPath) {
                        accessible.append(fullPath)
                    }
                }
                return accessible
            } catch {
                print("Error scanning root: \(error)")
                return []
            }
        }.value
        
        // Filter directories on MainActor - only skip virtual filesystems, not firmlink data
        let filteredDirs = accessibleDirs.filter { fullPath in
            !shouldSkipSystemPath(fullPath)
            // Note: Removed firmlinkResolver.isDataSide check to include actual system data
        }
            
        // Process accessible directories
        var items: [FolderItem] = []
        // Apply prioritization so important directories are scanned first
        let prioritizedDirs = SystemDirectoryFilter.prioritizedPaths(from: filteredDirs)
        let limitedDirs = prioritizedDirs // Scan ALL directories, prioritized order
            
            // PRE-CALCULATE: Start calculating sizes for all directories in parallel
            scanProgress = "Pre-calculating directory sizes..."
            scanProgressPercentage = 0.0
            
            // Start parallel size calculations for all directories
            await withTaskGroup(of: Void.self) { group in
                for dirPath in limitedDirs {
                    group.addTask {
                        let size = await DiskAnalyzer.getDirectoryTotalSizeFast(path: dirPath)
                        await MainActor.run {
                            // Always set; cache overwrite is fine
                            self.sizeCache[dirPath] = size
                        }
                    }
                }
            }
            
            scanProgress = "Starting analysis..."
            
            var totalScannedBytes: Int64 = 0
            
            // Parallelize root directory scanning using TaskGroup
            await withTaskGroup(of: FolderItem?.self) { group in
                for (index, dirPath) in limitedDirs.enumerated() {
                    group.addTask {
                        let nextPath = index + 1 < limitedDirs.count ? limitedDirs[index + 1] : nil
                        return await self.buildFolderItemSafelyWithCache(path: dirPath, nextPath: nextPath)
                    }
                }
                
                var completedCount = 0
                for await item in group {
                    if let item = item {
                        items.append(item)
                        totalScannedBytes += item.size
                        
                        // Update progress on main actor
                        await MainActor.run {
                            completedCount += 1
                            let dirName = URL(fileURLWithPath: item.path).lastPathComponent
                            self.scanProgress = "Analyzed \(dirName)... (\(completedCount)/\(limitedDirs.count))"
                            self.scanProgressPercentage = Double(completedCount) / Double(limitedDirs.count) * 100.0
                            
                            print("Completed scan of directory: \(item.path) (\(completedCount)/\(limitedDirs.count))")
                            
                            // Update whole-disk progress model
                            self.totalDiskScannedBytes = totalScannedBytes
                            if self.totalDiskBytes > 0 {
                                self.overallProgressPercentage = min(100.0, Double(totalScannedBytes) / Double(self.totalDiskBytes) * 100.0)
                            }
                            
                            // Update legacy properties
                            self.scannedBytes = totalScannedBytes
                            self.totalBytes = totalScannedBytes // For compatibility
                            
                            print("Completed \(item.path): \(item.size) bytes, total so far: \(totalScannedBytes) bytes (\(String(format: "%.2f", self.overallProgressPercentage))%)")
                        }
                    }
                }
            }
            
            // Final update
            scanProgressPercentage = 100.0
            
            // Update whole-disk progress model
            totalDiskScannedBytes = totalScannedBytes
            if totalDiskBytes > 0 {
                overallProgressPercentage = min(100.0, Double(totalScannedBytes) / Double(totalDiskBytes) * 100.0)
            }
            
            // Update legacy properties for backward compatibility
            totalBytes = totalScannedBytes
            scannedBytes = totalScannedBytes
            
            print("Scan complete! Total directories scanned: \(limitedDirs.count), Total size: \(totalScannedBytes) bytes")
            
        return items.sorted()
    }
    
    private func buildFolderItemSafelyWithCache(path: String, nextPath: String?) async -> FolderItem? {
        let url = URL(fileURLWithPath: path)
        do {
            let rv = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .contentModificationDateKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey
            ])
            let isDir = rv.isDirectory ?? false
            let modificationDate = rv.contentModificationDate ?? Date()
            var totalSize: Int64 = 0
            var children: [FolderItem] = []
            
            if isDir {
                // Get the total size first
                totalSize = await calculateDirectorySize(path: path, nextPath: nextPath)
                
                // Build the complete directory tree - all levels deep
                children = await buildDirectoryChildren(path: path, unlimited: true, visitedPaths: [])
                
                // Populate the folder tree cache for navigation
                await MainActor.run {
                    self.folderTree[path] = children
                    // Also cache all nested children for deeper navigation
                    self.cacheNestedFolderTree(children: children)
                }
                
                // Directory tree built successfully
            } else {
                if let t = rv.totalFileAllocatedSize { totalSize = Int64(t) }
                else if let a = rv.fileAllocatedSize { totalSize = Int64(a) }
            }
            
            var folderItem = FolderItem(
                name: url.lastPathComponent,
                path: path,
                size: totalSize,
                isDirectory: isDir,
                itemCount: children.isEmpty ? 1 : children.count,
                lastModified: modificationDate
            )
            
            // Set children after creating the item to avoid recursion issues
            folderItem.children = children
            
            return folderItem
        } catch {
            print("Error processing \(path): \(error)")
            return nil
        }
    }
    
    private nonisolated func shouldSkipDeepSystemScan(_ path: String) -> Bool {
        // System directories that should not be deeply scanned
        let systemPaths = [
            "/System",
            "/Library",
            "/private",
            "/usr",
            "/bin",
            "/sbin",
            "/cores",
            "/dev",
            "/etc",
            "/var",
            "/tmp"
        ]
        
        // Check if path is or is under a system directory
        for systemPath in systemPaths {
            if path == systemPath || path.hasPrefix(systemPath + "/") {
                return true
            }
        }
        
        // Also skip .app bundles and packages
        if path.contains(".app/") || path.hasSuffix(".app") {
            return true
        }
        
        return false
    }
    
    private func buildDirectoryChildren(path: String, unlimited: Bool = true, visitedPaths: Set<String> = []) async -> [FolderItem] {
        return await Task.detached { [weak self] in
            var children: [FolderItem] = []
            var currentVisited = visitedPaths
            
            if currentVisited.contains(path) {
                return []
            }
            currentVisited.insert(path)
            
            // Check if this is a system directory that shouldn't be deeply scanned
            let shouldSkipDeep = self?.shouldSkipDeepSystemScan(path) ?? false
            
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: path)
                
                let keys: Set<URLResourceKey> = [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                    .contentModificationDateKey
                ]
                
                for name in contents {
                    if Task.isCancelled { break }
                    
                    let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
                    let url = URL(fileURLWithPath: fullPath)
                    
                    do {
                        let resourceValues = try url.resourceValues(forKeys: keys)
                        if resourceValues.isSymbolicLink == true { continue }
                        
                        let isDir = resourceValues.isDirectory ?? false
                        var size: Int64 = 0
                        var childChildren: [FolderItem] = []
                        
                        if isDir {
                            // For system directories or their children, just get size without deep recursion
                            if shouldSkipDeep || self?.shouldSkipDeepSystemScan(fullPath) ?? false {
                                size = await DiskAnalyzer.getDirectoryTotalSizeFast(path: fullPath)
                                // Don't recurse into children (childChildren remains empty)
                            } else {
                                // Normal recursive scanning for user directories
                                childChildren = await self?.buildDirectoryChildren(
                                    path: fullPath,
                                    unlimited: true,
                                    visitedPaths: currentVisited
                                ) ?? []
                                size = childChildren.reduce(0) { $0 + $1.size }
                                
                                // Cache this directory's children
                                await MainActor.run { [weak self, fullPath, childChildren] in
                                    self?.folderTree[fullPath] = childChildren
                                }
                            }
                        } else {
                            size = Int64(resourceValues.totalFileAllocatedSize ?? 
                                       resourceValues.fileAllocatedSize ?? 0)
                        }
                        
                        var child = FolderItem(
                            name: name,
                            path: fullPath,
                            size: size,
                            isDirectory: isDir,
                            itemCount: isDir ? childChildren.count : 1,
                            lastModified: resourceValues.contentModificationDate ?? Date()
                        )
                        child.children = childChildren
                        children.append(child)
                        
                    } catch {
                        continue
                    }
                }
            } catch {
                return []
            }
            
            return children.sorted()
        }.value
    }
    
    
    // Helper method to recursively cache all nested folder structures
    private func cacheNestedFolderTree(children: [FolderItem]) {
        for child in children {
            if child.isDirectory && !child.children.isEmpty {
                // Cache this directory's children
                folderTree[child.path] = child.children
                // Recursively cache deeper levels
                cacheNestedFolderTree(children: child.children)
            }
            // Don't cache empty arrays for directories - let navigation trigger fresh scans
        }
    }
    
    
    private func calculateDirectorySize(path: String, nextPath: String? = nil) async -> Int64 {
        let folderName = URL(fileURLWithPath: path).lastPathComponent
        
        // Check if we already have the size cached
        var totalDirectorySize: Int64 = 0
        
        if let cachedSize = sizeCache[path] {
            // Use cached size instantly - no waiting!
            totalDirectorySize = cachedSize
            let capturedSize = totalDirectorySize
            await MainActor.run { [weak self, capturedSize, folderName, path] in
                self?.totalBytes = capturedSize
                self?.scanProgress = "Analyzing \(folderName)"
                self?.currentScanPath = path
                self?.scannedBytes = 0
                self?.scanProgressPercentage = 0.0
            }
        } else {
            // Need to calculate size first
            await MainActor.run { [weak self, folderName, path] in
                self?.scanProgress = "Getting size of \(folderName)..."
                self?.currentScanPath = path
                self?.scannedBytes = 0
                self?.totalBytes = 0
                self?.scanProgressPercentage = 0.0
            }
            
            totalDirectorySize = await DiskAnalyzer.getDirectoryTotalSizeFast(path: path)
            sizeCache[path] = totalDirectorySize
            
            let capturedSize = totalDirectorySize
            await MainActor.run { [weak self, capturedSize, folderName] in
                self?.totalBytes = capturedSize
                self?.scanProgress = "Analyzing \(folderName)"
            }
        }
        
        // PARALLEL: Start pre-calculating the next directory size while we analyze this one
        if let nextPath = nextPath, sizeCache[nextPath] == nil, sizePrecalculationTasks[nextPath] == nil {
            let capturedNextPath = nextPath // Capture for concurrent access
            sizePrecalculationTasks[nextPath] = Task { [weak self] in
                let size = await DiskAnalyzer.getDirectoryTotalSizeFast(path: capturedNextPath)
                await MainActor.run { [weak self] in
                    self?.sizeCache[capturedNextPath] = size
                    self?.sizePrecalculationTasks[capturedNextPath] = nil
                }
                return size
            }
        }
        
        // STEP 3: Detailed analysis with accurate progress bar using allocated size and URL prefetch
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .fileResourceIdentifierKey
        ]
        // Use Task.detached for file system operations to avoid MainActor isolation
        return await Task.detached {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                return totalDirectorySize
            }
            
            var processedSize: Int64 = 0
            var itemsProcessed = 0
            var lastProgressUpdate = 0
            // Match fast pass deduplication behavior
            let localSeen = ShardedFileIDSet(shardCount: 16)
            
            while let item = enumerator.nextObject() {
                guard let url = item as? URL else { continue }
                do {
                    let rv = try url.resourceValues(forKeys: keys)
                    if rv.isSymbolicLink == true { continue }
                    if rv.isRegularFile == true {
                        // Deduplicate hard-links to match fast pass behavior
                        if let id = rv.fileResourceIdentifier as? Data {
                            if !localSeen.insert(id) { continue }
                        }
                        
                        let sz = Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
                        processedSize += sz
                        itemsProcessed += 1
                        
                        // Update cumulative counter immediately for real-time progress
                        await self.cumulativeCounter.add(sz)
                        
                        if itemsProcessed - lastProgressUpdate >= 500 || (sz > 0 && processedSize % (10 * 1024 * 1024) < sz) {
                            lastProgressUpdate = itemsProcessed
                            // Capture values to avoid concurrency issues
                            let capturedSize = processedSize
                            let capturedTotal = max(totalDirectorySize, 1)
                            let capturedPercent = min(100.0, Double(capturedSize) / Double(capturedTotal) * 100.0)
                            let capturedCumulative = await self.cumulativeCounter.getValue()
                            await MainActor.run {
                                // Update per-directory progress
                                self.currentDirScannedBytes = capturedSize
                                self.currentDirTotalBytes = capturedTotal
                                self.currentDirPercent = capturedPercent
                                self.scanProgressPercentage = capturedPercent
                                
                                // Update real-time cumulative progress
                                self.totalDiskScannedBytes = capturedCumulative
                                
                                // Update legacy properties for backward compatibility
                                self.scannedBytes = capturedSize
                            }
                        }
                    }
                } catch {
                    continue
                }
                if Task.isCancelled { break }
            }
            
            // Final update - use actual processed size, not precalculated estimate
            // Capture final values to avoid concurrency issues
            let finalProcessedSize = processedSize
            let finalTotalSize = max(totalDirectorySize, processedSize)
            let finalCumulative = await self.cumulativeCounter.getValue()
            await MainActor.run {
                self.currentDirScannedBytes = finalProcessedSize
                self.currentDirTotalBytes = finalTotalSize
                self.currentDirPercent = 100.0
                self.scanProgressPercentage = 100.0
                
                // Update final cumulative progress
                self.totalDiskScannedBytes = finalCumulative
                
                // Update legacy properties
                self.scannedBytes = finalProcessedSize
            }
            
            return max(totalDirectorySize, finalProcessedSize) // Return the larger of estimate vs actual
        }.value
    }
    
    // MARK: - Enhanced FSEvents Monitoring Integration
    
    private func startFileSystemMonitoring(for path: String) async {
        // Start monitoring with optimized latency
        fileSystemMonitor.startMonitoring(
            paths: [path],
            latency: 0.5 // More responsive updates
        ) { [weak self] change in
            Task { @MainActor in
                self?.handleFileSystemChange(change)
            }
        }
    }
    
    private func handleFileSystemChange(_ change: FileSystemMonitor.FileSystemChange) {
        print("File system change detected: \(change.path)")
        
        // Invalidate caches for affected paths
        let affectedPath = change.path
        let parentPath = URL(fileURLWithPath: affectedPath).deletingLastPathComponent().path
        
        // Remove from various caches
        sizeCache.removeValue(forKey: affectedPath)
        sizeCache.removeValue(forKey: parentPath)
        folderTree.removeValue(forKey: affectedPath)
        folderTree.removeValue(forKey: parentPath)
        
        // For significant changes, trigger a partial rescan
        if change.isCreated || change.isRemoved {
            // Could implement incremental updates here
            print("Significant change detected, consider partial rescan for: \(parentPath)")
        }
    }
    
    // MARK: - Recursive Scanning
    
    private func scanDirectoryRecursive(_ path: String) async -> [FolderItem] {
        return await Task.detached {
            var items: [FolderItem] = []
            
            do {
                let resourceKeys: Set<URLResourceKey> = [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey,
                    .contentModificationDateKey
                ]
                
                let contents = try FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: path),
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsPackageDescendants]
                )
                
                for url in contents {
                    do {
                        let rv = try url.resourceValues(forKeys: resourceKeys)
                        if rv.isSymbolicLink == true { continue }
                        
                        let isDir = rv.isDirectory ?? false
                        let name = url.lastPathComponent
                        let modDate = rv.contentModificationDate ?? Date()
                        
                        if isDir {
                            // Recursively build the complete subtree
                            let children = await self.scanDirectoryRecursive(url.path)
                            let dirSize = children.reduce(0) { $0 + $1.size }
                            
                            var item = FolderItem(
                                name: name,
                                path: url.path,
                                size: dirSize,
                                isDirectory: true,
                                itemCount: children.count,
                                lastModified: modDate
                            )
                            item.children = children
                            items.append(item)
                            
                        } else if rv.isRegularFile == true {
                            let size = Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
                            items.append(FolderItem(
                                name: name,
                                path: url.path,
                                size: size,
                                isDirectory: false,
                                itemCount: 1,
                                lastModified: modDate
                            ))
                        }
                    } catch {
                        // Skip inaccessible items
                        continue
                    }
                }
            } catch {
                print("Error scanning \(path): \(error)")
            }
            
            return items.sorted()
        }.value
    }
    
    // MARK: - Enhanced Memory Management
    
    /// Enhanced scanning with better memory management
    private func performOptimizedScan(path: String) async -> [FolderItem] {
        return await asyncAutoreleasePool {
            // Use the optimized scanner for better performance
            await self.optimizedScanner.scanDirectoryOptimized(
                path,
                enableMonitoring: false // We handle monitoring separately
            ) { [weak self] progress, message in
                Task { @MainActor in
                    self?.scanProgressPercentage = progress
                    self?.scanProgress = message
                }
            }
        }
    }
    
    public nonisolated static func getDirectoryTotalSizeFast(path: String) async -> Int64 {
        return await Task.detached {
            var totalSize: Int64 = 0
            var fileCount: Int = 0
            var errorCount: Int = 0
            let localSeen = ShardedFileIDSet(shardCount: 16)
            
            // Try to use optimized bulk scanning first
            do {
                let dirFd = open(path, O_RDONLY)
                if dirFd >= 0 {
                    defer { close(dirFd) }
                    
                    // Use the fast getattrlistbulk syscall for immediate children
                    let scanEntries = try bulkScanDirectoryOptimized(dirFd: dirFd)
                    let entries = scanEntries.map { entry in
                        DirectoryEntry(
                            name: entry.name,
                            isDir: entry.isDir,
                            allocSize: entry.allocSize,
                            deviceId: entry.deviceId,
                            inode: entry.inode
                        )
                    }
                    
                    for entry in entries {
                        if !entry.isDir {
                            fileCount += 1
                            // Use device+inode for deduplication - convert to Data
                            var devIno = FileDeviceInode(dev: entry.deviceId, ino: entry.inode)
                            let devInoData = withUnsafeBytes(of: &devIno) { Data($0) }
                            if localSeen.insert(devInoData) {
                                totalSize += entry.allocSize
                            }
                        } else {
                            // Recursively scan subdirectories
                            let subPath = path.hasSuffix("/") ? path + entry.name : path + "/" + entry.name
                            let subSize = await getDirectoryTotalSizeFast(path: subPath)
                            totalSize += subSize
                        }
                    }
                    
                    return totalSize
                } else {
                    throw NSError(domain: "FileSystem", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Cannot open directory"])
                }
            } catch {
                // Fallback to FileManager if bulk scan fails
                do {
                    let keys: Set<URLResourceKey> = [
                        .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
                        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                        .fileResourceIdentifierKey
                    ]
                    
                    let contentsData = try FileManager.default.contentsOfDirectory(
                        at: URL(fileURLWithPath: path),
                        includingPropertiesForKeys: Array(keys),
                        options: [.skipsPackageDescendants]
                    )
                    
                    for url in contentsData {
                        do {
                            let rv = try url.resourceValues(forKeys: keys)
                            
                            if rv.isSymbolicLink == true { continue }
                            
                            if rv.isDirectory == true {
                                let subSize = await getDirectoryTotalSizeFast(path: url.path)
                                totalSize += subSize
                            } else if rv.isRegularFile == true {
                                fileCount += 1
                                
                                // Deduplicate hard-links
                                if let id = rv.fileResourceIdentifier as? Data {
                                    if !localSeen.insert(id) { continue }
                                }
                                
                                let sz = Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
                                totalSize += sz
                            }
                        } catch {
                            errorCount += 1
                            continue
                        }
                    }
                    
                    return totalSize
                } catch {
                    return 0
                }
            }
        }.value
    }
    
    private func scanDirectoryContentsSafe(_ path: String) async -> [FolderItem] {
        return await Task.detached {
            do {
                let keys: Set<URLResourceKey> = [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                    .contentModificationDateKey, .fileResourceIdentifierKey
                ]
                
                let contents = try FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: path),
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsPackageDescendants]
                )
                
                // Separate files and directories for different processing
                var files: [FolderItem] = []
                var directoriesNeedingSize: [(url: URL, item: FolderItem)] = []
                
                for url in contents {
                    do {
                        let rv = try url.resourceValues(forKeys: keys)
                        if rv.isSymbolicLink == true { continue }
                        
                        let isDir = rv.isDirectory ?? false
                        let modificationDate = rv.contentModificationDate ?? Date()
                        
                        if isDir {
                            // Create directory item without size for now
                            let item = FolderItem(
                                name: url.lastPathComponent,
                                path: url.path,
                                size: 0, // Will be calculated in parallel
                                isDirectory: true,
                                itemCount: 1,
                                lastModified: modificationDate
                            )
                            directoriesNeedingSize.append((url: url, item: item))
                        } else if rv.isRegularFile == true {
                            let size = Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
                            let item = FolderItem(
                                name: url.lastPathComponent,
                                path: url.path,
                                size: size,
                                isDirectory: false,
                                itemCount: 1,
                                lastModified: modificationDate
                            )
                            files.append(item)
                        }
                        
                    } catch {
                        // Skip items that can't be accessed
                        continue
                    }
                }
                
                // Calculate directory sizes in parallel for better performance
                let directoriesWithSizes = await withTaskGroup(of: FolderItem.self, returning: [FolderItem].self) { taskGroup in
                    var results: [FolderItem] = []
                    
                    for (_, item) in directoriesNeedingSize {
                        taskGroup.addTask {
                            let size = await DiskAnalyzer.getDirectoryTotalSizeFast(path: item.path)
                            return FolderItem(
                                name: item.name,
                                path: item.path,
                                size: size,
                                isDirectory: item.isDirectory,
                                itemCount: item.itemCount,
                                lastModified: item.lastModified
                            )
                        }
                    }
                    
                    for await result in taskGroup {
                        results.append(result)
                    }
                    
                    return results
                }
                
                // Combine files and directories with calculated sizes
                var allItems = files
                allItems.append(contentsOf: directoriesWithSizes)
                
                return allItems.sorted()
                
            } catch {
                print("Error scanning directory \(path): \(error)")
                return []
            }
        }.value
    }
    
    // MARK: - External Volumes
    
    func scanExternalVolumes() async {
        let volumes = await Task.detached {
            var externalVolumes: [FolderItem] = []
            
            // Scan /Volumes for external drives and networks
            let volumesPath = "/Volumes"
            do {
                let volumeList = try FileManager.default.contentsOfDirectory(atPath: volumesPath)
                
                for volumeName in volumeList {
                    let volumePath = volumesPath + "/" + volumeName
                    
                    // Skip system volumes and hidden volumes
                    if volumeName.hasPrefix(".") ||
                       volumeName == "Macintosh HD" ||
                       volumeName.contains("com.apple.TimeMachine") {
                        continue
                    }
                    
                    // Check if it's accessible
                    guard FileManager.default.isReadableFile(atPath: volumePath) else {
                        continue
                    }
                    
                    let volumeURL = URL(fileURLWithPath: volumePath)
                    do {
                        let resourceValues = try volumeURL.resourceValues(forKeys: [
                            .volumeNameKey,
                            .volumeTotalCapacityKey,
                            .volumeAvailableCapacityKey
                        ])
                        
                        let size = Int64(resourceValues.volumeTotalCapacity ?? 0)
                        
                        let volume = FolderItem(
                            name: volumeName,
                            path: volumePath,
                            size: size,
                            isDirectory: true,
                            itemCount: 1,
                            lastModified: Date()
                        )
                        
                        externalVolumes.append(volume)
                        
                    } catch {
                        // If we can't get volume info, create a basic item
                        let volume = FolderItem(
                            name: volumeName,
                            path: volumePath,
                            size: 0,
                            isDirectory: true,
                            itemCount: 1,
                            lastModified: Date()
                        )
                        
                        externalVolumes.append(volume)
                    }
                }
                
            } catch {
                print("Error scanning /Volumes: \(error)")
            }
            
            return externalVolumes.sorted()
        }.value
        
        await MainActor.run {
            self.externalVolumes = volumes
        }
    }
    
    // MARK: - Helper Functions
    
    private func hasFullDiskAccess() -> Bool {
        let testPaths = [
            "/Library/Application Support",
            "/Library/Preferences",
            "/private/var/db"
        ]
        
        for path in testPaths {
            if !FileManager.default.isReadableFile(atPath: path) {
                return false
            }
            
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: path)
                return true
            } catch {
                return false
            }
        }
        return true
    }
    
    private func getTotalDiskSize(path: String) -> Int64 {
        do {
            let url = URL(fileURLWithPath: path)
            let resourceValues = try url.resourceValues(forKeys: [.volumeTotalCapacityKey])
            return Int64(resourceValues.volumeTotalCapacity ?? 0)
        } catch {
            return 0
        }
    }
    
    private func shouldSkipSystemPath(_ path: String) -> Bool {
        let pathsToSkip = [
            "/dev",
            "/proc",
            "/tmp",
            "/var/run",
            "/var/tmp",
            "/System/Volumes/Data/.Trashes"
        ]
        
        for skipPath in pathsToSkip {
            if path == skipPath || path.hasPrefix(skipPath + "/") {
                return true
            }
        }
        
        return false
    }
    
    func clearAllCaches() {
        optimizedScanner.clearAllCaches()
        smartCache.clearAllCaches()
        folderTree.removeAll()
        sizeCache.removeAll()
        // Cancel any pending size precalculation tasks
        for (_, task) in sizePrecalculationTasks {
            task.cancel()
        }
        sizePrecalculationTasks.removeAll()
    }
}

// MARK: - Supporting Types moved to SharedTypes.swift

// Bulk scanning functionality moved to BulkScanningService.swift

// MARK: - Autoreleasepool moved to SharedTypes.swift
