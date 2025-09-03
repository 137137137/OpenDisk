import Foundation
import Darwin

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
    
    // Navigate to a path using pre-calculated data
    // Returns true if cached data was found and loaded, false otherwise
    func navigateToPath(_ path: String) -> Bool {
        print("DEBUG: navigateToPath called for: \(path)")
        print("DEBUG: folderTree has \(folderTree.count) cached paths: \(Array(folderTree.keys))")
        
        // Check if we already have data for this exact path
        if path == currentRootItemsPath && !rootItems.isEmpty && !isScanning {
            print("DEBUG: Using existing data for \(path)")
            // Already have data for this path loaded, no need to rescan
            calculatePercentages()
            return true
        }
        
        // Check folder tree cache for other paths
        if let preCalculatedItems = folderTree[path] {
            print("DEBUG: Found cached data for \(path) with \(preCalculatedItems.count) items")
            
            // If cached data is empty, it might be due to permissions
            // Don't use empty cache - let the caller trigger a direct scan instead
            if preCalculatedItems.isEmpty {
                print("DEBUG: Cached data is empty for \(path) - returning false to trigger direct scan")
                return false
            }
            
            rootItems = preCalculatedItems
            currentRootItemsPath = path
            totalSize = preCalculatedItems.reduce(0) { $0 + $1.size }
            calculatePercentages()
            return true
        }
        
        print("DEBUG: No cached data found for \(path)")
        return false
    }
    
    func scanDirectory(_ path: String) {
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
                        
                        // Cache the folder tree for navigation - this was missing!
                        // Don't cache this directory as its own children, that would be wrong
                        // Instead, pre-scan immediate subdirectories for navigation
                        self.preloadSubdirectoryCache(items: optimizedItems)
                        
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
            
            for (index, dirPath) in limitedDirs.enumerated() {
                // Get next directory for parallel pre-calculation (if any)
                let nextPath = index + 1 < limitedDirs.count ? limitedDirs[index + 1] : nil
                
                let dirName = URL(fileURLWithPath: dirPath).lastPathComponent
                scanProgress = "Analyzing \(dirName)... (\(index + 1)/\(limitedDirs.count))"
                scanProgressPercentage = Double(index) / Double(limitedDirs.count) * 100.0
                
                print("Starting scan of directory: \(dirPath) (\(index + 1)/\(limitedDirs.count))")
                
                if let item = await buildFolderItemSafelyWithCache(path: dirPath, nextPath: nextPath) {
                    items.append(item)
                    totalScannedBytes += item.size
                    
                    // Update whole-disk progress model
                    totalDiskScannedBytes = totalScannedBytes
                    if totalDiskBytes > 0 {
                        overallProgressPercentage = min(100.0, Double(totalScannedBytes) / Double(totalDiskBytes) * 100.0)
                    }
                    
                    // Update legacy properties
                    scannedBytes = totalScannedBytes
                    totalBytes = totalScannedBytes // For compatibility
                    
                    print("Completed \(dirPath): \(item.size) bytes, total so far: \(totalScannedBytes) bytes (\(String(format: "%.2f", overallProgressPercentage))%)")
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
                children = await DiskAnalyzer.buildDirectoryChildren(path: path, unlimited: true, visitedPaths: [])
                
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
    
    private static func buildDirectoryChildren(path: String, unlimited: Bool = true, visitedPaths: Set<String> = []) async -> [FolderItem] {
        return await Task.detached {
            var children: [FolderItem] = []
            var currentVisited = visitedPaths
            
            // Prevent infinite recursion by checking if we've already visited this path
            if currentVisited.contains(path) {
                print("Cycle detected, skipping path: \(path)")
                return []
            }
            currentVisited.insert(path)
            
            // Use FileManager approach for reliable directory enumeration
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: path)
                
                let keys: Set<URLResourceKey> = [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                    .contentModificationDateKey
                ]
                
                for name in contents {
                    if Task.isCancelled {
                        print("Task cancelled while scanning \(path)")
                        break
                    }
                    
                    let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
                    let url = URL(fileURLWithPath: fullPath)
                    
                    // Process each item with proper memory management
                    do {
                        let resourceValues = try url.resourceValues(forKeys: keys)
                        
                        // Skip symbolic links to avoid cycles
                        if resourceValues.isSymbolicLink == true { continue }
                        
                        let isDir = resourceValues.isDirectory ?? false
                        let isRegular = resourceValues.isRegularFile ?? false
                        var size: Int64 = 0
                        var childChildren: [FolderItem] = []
                        
                        if isRegular {
                            // Get file size
                            size = Int64(resourceValues.totalFileAllocatedSize ?? 
                                       resourceValues.fileAllocatedSize ?? 0)
                        } else if isDir {
                            // For directories, scan children unless they are system directories
                            // that would negatively impact performance
                            if unlimited && !shouldSkipDeepScan(fullPath) {
                                childChildren = await buildDirectoryChildren(path: fullPath, unlimited: false, visitedPaths: currentVisited)
                                size = childChildren.reduce(0) { $0 + $1.size }
                            } else {
                                // For system directories, just get the size without enumerating children
                                size = await DiskAnalyzer.getDirectoryTotalSizeFast(path: fullPath)
                            }
                        }
                        
                        let modificationDate = resourceValues.contentModificationDate ?? Date()
                        
                        var child = FolderItem(
                            name: name,
                            path: fullPath,
                            size: size,
                            isDirectory: isDir,
                            itemCount: isDir ? (childChildren.isEmpty ? 1 : childChildren.count) : 1,
                            lastModified: modificationDate
                        )
                        child.children = childChildren
                        children.append(child)
                        
                    } catch {
                        // Skip items that can't be accessed due to permissions
                        continue
                    }
                }
            } catch {
                // Silently skip directories that can't be read
                return []
            }
            
            return children.sorted()
        }.value
    }
    
    // Helper method to determine if we should skip system directories for performance
    private static nonisolated func shouldSkipDeepScan(_ path: String) -> Bool {
        let skipPaths = [
            "/System/Volumes/",
            "/System/Library/PrivateFrameworks/",
            "/System/Library/Frameworks/",
            "/Library/Developer/",
            "/usr/lib/",
            "/usr/share/",
            "/.DocumentRevisions",
            "/.Spotlight-V100",
            "/.fseventsd",
            "/.Trashes",
            "/Network/",
            "/Volumes/.timemachine"
        ]
        
        for skipPath in skipPaths {
            if path.hasPrefix(skipPath) {
                print("DEBUG: Skipping deep scan of system directory: \(path)")
                return true
            }
        }
        
        // No depth limit - scan as deep as needed for complete enumeration
        return false
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
        }
    }
    
    // Preload immediate subdirectory contents for faster navigation
    private func preloadSubdirectoryCache(items: [FolderItem]) {
        print("DEBUG: preloadSubdirectoryCache called with \(items.count) items")
        let directories = items.filter { $0.isDirectory }
        print("DEBUG: Found \(directories.count) directories to preload: \(directories.map { $0.path })")
        
        Task {
            for item in items where item.isDirectory {
                print("DEBUG: Preloading cache for directory: \(item.path)")
                // Use the optimized scanner to quickly scan immediate subdirectory contents
                let subItems = await self.optimizedScanner.scanDirectoryOptimized(
                    item.path,
                    enableMonitoring: false // Don't enable monitoring for preload scans
                ) { _, _ in
                    // Silent progress for background preloading
                }
                
                print("DEBUG: Scanned \(item.path) and found \(subItems.count) subitems")
                
                // Always cache the result, even if empty - this prevents re-scanning
                await MainActor.run {
                    self.folderTree[item.path] = subItems.sorted()
                    print("DEBUG: Cached \(subItems.count) items for \(item.path)")
                }
                
                // If we got no items, this might be a permissions issue
                if subItems.isEmpty {
                    print("DEBUG: WARNING - No items found in \(item.path). Possible permissions issue.")
                }
            }
            await MainActor.run {
                print("DEBUG: Preloading complete. Total cached paths: \(self.folderTree.count)")
            }
        }
    }
    
    private func buildFolderItemSafely(path: String) async -> FolderItem? {
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
            if isDir {
                totalSize = await calculateDirectorySize(path: path)
            } else {
                if let t = rv.totalFileAllocatedSize { totalSize = Int64(t) }
                else if let a = rv.fileAllocatedSize { totalSize = Int64(a) }
            }
            return FolderItem(
                name: url.lastPathComponent,
                path: path,
                size: totalSize,
                isDirectory: true,
                itemCount: 1,
                lastModified: modificationDate
            )
        } catch {
            print("Error processing \(path): \(error)")
            return nil
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
                        
                        if itemsProcessed - lastProgressUpdate >= 500 || (sz > 0 && processedSize % (10 * 1024 * 1024) < sz) {
                            lastProgressUpdate = itemsProcessed
                            // Capture values to avoid concurrency issues
                            let capturedSize = processedSize
                            let capturedTotal = max(totalDirectorySize, 1)
                            let capturedPercent = min(100.0, Double(capturedSize) / Double(capturedTotal) * 100.0)
                            await MainActor.run {
                                // Update per-directory progress
                                self.currentDirScannedBytes = capturedSize
                                self.currentDirTotalBytes = capturedTotal
                                self.currentDirPercent = capturedPercent
                                self.scanProgressPercentage = capturedPercent
                                
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
            await MainActor.run {
                self.currentDirScannedBytes = finalProcessedSize
                self.currentDirTotalBytes = finalTotalSize
                self.currentDirPercent = 100.0
                self.scanProgressPercentage = 100.0
                
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
            var items: [FolderItem] = []
            
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
                
                for url in contents {
                    do {
                        let rv = try url.resourceValues(forKeys: keys)
                        if rv.isSymbolicLink == true { continue }
                        
                        let isDir = rv.isDirectory ?? false
                        var size: Int64 = 0
                        let modificationDate = rv.contentModificationDate ?? Date()
                        
                        if isDir {
                            size = await DiskAnalyzer.getDirectoryTotalSizeFast(path: url.path)
                        } else if rv.isRegularFile == true {
                            if let t = rv.totalFileAllocatedSize { size = Int64(t) }
                            else if let a = rv.fileAllocatedSize { size = Int64(a) }
                        }
                        
                        let item = FolderItem(
                            name: url.lastPathComponent,
                            path: url.path,
                            size: size,
                            isDirectory: isDir,
                            itemCount: 1,
                            lastModified: modificationDate
                        )
                        
                        items.append(item)
                        
                    } catch {
                        // Skip items that can't be accessed
                        continue
                    }
                }
                
            } catch {
                print("Error scanning directory \(path): \(error)")
                return []
            }
            
            return items.sorted()
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
}

// MARK: - Supporting Types moved to SharedTypes.swift

// Bulk scanning functionality moved to BulkScanningService.swift

// MARK: - Autoreleasepool moved to SharedTypes.swift
