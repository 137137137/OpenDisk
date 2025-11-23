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

    // DEBUG: Live file scanning progress (scrollable log)
    @Published var debugScanLog: [String] = []
    @Published var debugFilesScannedCount: Int = 0
    @Published var debugEnabled: Bool = false
    
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
    
    // HYPER: Ultra-fast scanner using getattrlistbulk
    private let hyperScanner = HyperScanner()
    private let fileSystemMonitor = FileSystemMonitor()

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
        scanProgress = "Preparing high-performance scan..."
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

        // Reset debug fields
        debugScanLog = []
        debugFilesScannedCount = 0

        // Get total USED disk space for accurate progress tracking
        // This matches the sidebar display and what we're actually scanning
        if path == "/" {
            totalDiskBytes = getTotalDiskSize(path: path) // Gets USED bytes, not total capacity
        } else {
            // For subdirectory scans, we could get the directory's total size
            // but for now we'll rely on estimates
            totalDiskBytes = 0
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
        
        // Reset dedupe set for this scan
        
        scanTask = Task { [weak self] in
            guard let self = self else { return }

            // Create local copies of captured variables to avoid concurrency issues
            let pathToScan = scanPath

            // HYPER MODE: Use getattrlistbulk for maximum performance
            // This matches DaisyDisk speed
            await MainActor.run {
                self.scanProgress = "Initializing hyper-fast scan..."
                self.scanProgressPercentage = 0
            }

            let hyperResult = await self.hyperScanner.scan(
                url: URL(fileURLWithPath: pathToScan)
            ) { progress in
                Task { @MainActor in
                    self.scanProgressPercentage = progress.fractionCompleted * 100.0
                    self.scannedBytes = progress.scannedBytes
                    self.totalBytes = progress.totalUsedBytes
                    self.overallProgressPercentage = progress.fractionCompleted * 100.0

                    let sizeStr = ByteCountFormatter.string(fromByteCount: progress.scannedBytes, countStyle: .file)
                    self.scanProgress = "Scanning: \(sizeStr) (\(progress.itemsScanned.formatted()) items)"
                    self.currentScanPath = progress.currentPath

                    // Update files per second
                    if let startTime = self.scanStartTime {
                        let elapsed = Date().timeIntervalSince(startTime)
                        if elapsed > 0 {
                            let rate = Double(progress.itemsScanned) / elapsed
                            self.filesPerSecond = String(format: "%.0f files/sec", rate)

                            // Estimate time remaining
                            if progress.fractionCompleted > 0 {
                                let estimatedTotal = elapsed / progress.fractionCompleted
                                let remaining = estimatedTotal - elapsed
                                if remaining > 0 {
                                    self.estimatedTimeRemaining = self.formatTimeInterval(remaining)
                                }
                            }
                        }
                    }
                }
            }

            // Convert to FolderItems
            let rootItem = hyperResult.toFolderItem()
            let items = rootItem.children

            await MainActor.run {
                self.rootItems = items.sorted()
                self.currentRootItemsPath = path
                // Cache the scan results for navigation
                self.folderTree[path] = items.sorted()
                self.totalSize = items.reduce(0) { $0 + $1.size }
                self.calculatePercentages()

                self.isScanning = false
                self.scanProgress = "Scan complete (hyper-speed)"
                self.scanProgressPercentage = 100.0
                self.estimatedTimeRemaining = ""

                if let startTime = self.scanStartTime {
                    let elapsed = Date().timeIntervalSince(startTime)
                    print("HYPER SCAN: Completed \(items.count) items in \(String(format: "%.2f", elapsed))s")
                }
            }

            // Scan external volumes in parallel
            await self.scanExternalVolumes()

            // Start FSEvents monitoring for real-time updates
            if pathToScan != "/" {
                await self.startFileSystemMonitoring(for: pathToScan)
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
            
            // Scan directories with limited concurrency to prevent system overwhelm
            let maxConcurrentScans = 3 // Limit concurrent root directory scans
            await withTaskGroup(of: (Int, FolderItem?).self) { group in
                var activeTasks = 0
                var nextIndex = 0
                
                // Start initial batch of tasks
                for index in 0..<min(maxConcurrentScans, limitedDirs.count) {
                    let dirPath = limitedDirs[index]
                    group.addTask {
                        let nextPath = index + 1 < limitedDirs.count ? limitedDirs[index + 1] : nil
                        let result = await self.buildFolderItemSafelyWithTimeout(path: dirPath, nextPath: nextPath, timeoutSeconds: 300) // 5 minute timeout
                        return (index, result)
                    }
                    activeTasks += 1
                    nextIndex = index + 1
                }
                
                var completedCount = 0
                var results: [FolderItem?] = Array(repeating: nil, count: limitedDirs.count)
                
                // Process completed tasks and start new ones
                for await (completedIndex, item) in group {
                    results[completedIndex] = item
                    activeTasks -= 1
                    completedCount += 1
                    
                    // Start next task if available
                    if nextIndex < limitedDirs.count {
                        let dirPath = limitedDirs[nextIndex]
                        let index = nextIndex
                        group.addTask {
                            let nextPath = index + 1 < limitedDirs.count ? limitedDirs[index + 1] : nil
                            let result = await self.buildFolderItemSafelyWithTimeout(path: dirPath, nextPath: nextPath, timeoutSeconds: 300)
                            return (index, result)
                        }
                        activeTasks += 1
                        nextIndex += 1
                    }
                    
                    // Update progress
                    if let item = item {
                        totalScannedBytes += item.size
                        await MainActor.run {
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
                    } else {
                        let dirPath = limitedDirs[completedIndex]
                        await MainActor.run {
                            print("TIMEOUT/ERROR: Scan of \(dirPath) failed or timed out")
                            self.scanProgress = "Skipped \(URL(fileURLWithPath: dirPath).lastPathComponent) (timeout)... (\(completedCount)/\(limitedDirs.count))"
                        }
                    }
                }
                
                // Add all successful results to items array
                for result in results {
                    if let item = result {
                        items.append(item)
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
    
    // Timeout wrapper for buildFolderItemSafelyWithCache
    private func buildFolderItemSafelyWithTimeout(path: String, nextPath: String?, timeoutSeconds: Double) async -> FolderItem? {
        await withTaskGroup(of: FolderItem?.self) { group in
            group.addTask {
                await self.buildFolderItemSafelyWithCache(path: path, nextPath: nextPath)
            }
            
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return nil // Return nil on timeout
            }
            
            // Return first result (either success or timeout)
            for await result in group {
                group.cancelAll() // Cancel remaining task
                return result
            }
            
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
    
    private func buildDirectoryChildren(path: String, unlimited: Bool = true, visitedPaths: Set<String> = [], depth: Int = 0) async -> [FolderItem] {
        // CRASH FIX: Prevent stack overflow from excessive recursion
        let MAX_DEPTH = 50
        if depth > MAX_DEPTH {
            print("WARNING: Max recursion depth reached at path: \(path)")
            return []
        }

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

                // PERFORMANCE: Check if this looks like a generated/dependency directory
                let dirName = URL(fileURLWithPath: path).lastPathComponent
                let isLikelyGenerated = self?.isGeneratedDirectory(dirName: dirName, itemCount: contents.count) ?? false

                if isLikelyGenerated && contents.count > 1000 {
                    // For large generated directories, use smart aggregation
                    let totalSize = await DiskAnalyzer.getDirectoryTotalSizeFast(path: path)

                    let aggregatedName = self?.getSmartAggregatedName(
                        dirName: dirName,
                        itemCount: contents.count
                    ) ?? dirName

                    var aggregatedItem = FolderItem(
                        name: aggregatedName,
                        path: path,
                        size: totalSize,
                        isDirectory: true,
                        itemCount: contents.count,
                        lastModified: Date()
                    )

                    // Add a placeholder child to indicate aggregation
                    aggregatedItem.children = [
                        FolderItem(
                            name: "📊 \(contents.count.formatted()) items aggregated for performance",
                            path: path + "/__aggregated__",
                            size: totalSize,
                            isDirectory: false,
                            itemCount: contents.count,
                            lastModified: Date()
                        )
                    ]

                    return [aggregatedItem]
                }

                let keys: Set<URLResourceKey> = [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                    .contentModificationDateKey
                ]

                // PERFORMANCE: Use sampling for very large directories
                let itemsToProcess = contents.count > 10000 ?
                    Array(contents.prefix(1000)) + [" ... \(contents.count - 1000) more items"] :
                    contents

                for name in itemsToProcess {
                    if Task.isCancelled { break }

                    // Handle aggregated placeholder
                    if name.starts(with: " ... ") {
                        // Calculate remaining size
                        let remainingSize = await DiskAnalyzer.getDirectoryTotalSizeFast(path: path) -
                            children.reduce(0) { $0 + $1.size }

                        children.append(FolderItem(
                            name: name,
                            path: path + "/__remaining__",
                            size: max(0, remainingSize),
                            isDirectory: false,
                            itemCount: contents.count - 1000,
                            lastModified: Date()
                        ))
                        continue
                    }

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
                                // Check if this subdirectory is also likely generated
                                let subContents = try? FileManager.default.contentsOfDirectory(atPath: fullPath)
                                let subItemCount = subContents?.count ?? 0

                                if self?.isGeneratedDirectory(dirName: name, itemCount: subItemCount) ?? false && subItemCount > 1000 {
                                    // Aggregate this subdirectory too
                                    size = await DiskAnalyzer.getDirectoryTotalSizeFast(path: fullPath)
                                    // Don't recurse - leave children empty
                                } else {
                                    // Normal recursive scanning for user directories
                                    childChildren = await self?.buildDirectoryChildren(
                                        path: fullPath,
                                        unlimited: true,
                                        visitedPaths: currentVisited,
                                        depth: depth + 1
                                    ) ?? []
                                    size = childChildren.isEmpty ?
                                        await DiskAnalyzer.getDirectoryTotalSizeFast(path: fullPath) :
                                        childChildren.reduce(0) { $0 + $1.size }

                                    // Cache this directory's children
                                    if !childChildren.isEmpty {
                                        await MainActor.run { [weak self, fullPath, childChildren] in
                                            self?.folderTree[fullPath] = childChildren
                                        }
                                    }
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
                            itemCount: isDir ? max(1, childChildren.count) : 1,
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
            sizePrecalculationTasks[capturedNextPath] = Task { [weak self] in
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
            var localSeen = Set<Data>()

            while let item = enumerator.nextObject() {
                guard let url = item as? URL else { continue }
                do {
                    let rv = try url.resourceValues(forKeys: keys)
                    if rv.isSymbolicLink == true { continue }
                    if rv.isRegularFile == true {
                        // Deduplicate hard-links to match fast pass behavior
                        if let id = rv.fileResourceIdentifier as? Data {
                            if !localSeen.insert(id).inserted { continue }
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
                            let capturedPath = url.path
                            let capturedFileSize = sz
                            let capturedCount = itemsProcessed

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

                                // DEBUG: Add to log if enabled
                                self.debugFilesScannedCount = capturedCount
                                if self.debugEnabled {
                                    let sizeStr = ByteCountFormatter.string(fromByteCount: capturedFileSize, countStyle: .file)
                                    let logEntry = "[\(capturedCount)] \(capturedPath) (\(sizeStr))"
                                    self.debugScanLog.append(logEntry)
                                    // Keep only last 100 entries
                                    if self.debugScanLog.count > 100 {
                                        self.debugScanLog.removeFirst(self.debugScanLog.count - 100)
                                    }
                                }
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
    
    public nonisolated static func getDirectoryTotalSizeFast(path: String) async -> Int64 {
        return await Task.detached {
            var totalSize: Int64 = 0

            // Simple FileManager enumeration for total size
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            )

            while let url = enumerator?.nextObject() as? URL {
                if let resourceValues = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                   let size = resourceValues.totalFileAllocatedSize {
                    totalSize += Int64(size)
                }
            }

            return totalSize
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

    private nonisolated func isGeneratedDirectory(dirName: String, itemCount: Int) -> Bool {
        // Performance-based detection - not name based!
        // Large directories with many items are likely generated
        if itemCount > 5000 {
            return true
        }

        // Common patterns that indicate generated content (but also check item count)
        let patterns = [
            "node_modules", ".git", "venv", ".venv", "vendor",
            "target", "build", "dist", ".next", "Pods", "packages",
            "bower_components", ".gradle", ".m2", "cargo",
            "__pycache__", ".pytest_cache", ".tox", "htmlcov",
            "DerivedData", ".build", ".swiftpm"
        ]

        // Only treat as generated if it matches pattern AND has many items
        if patterns.contains(dirName) && itemCount > 100 {
            return true
        }

        // Directories starting with . and having many items
        if dirName.hasPrefix(".") && itemCount > 500 {
            return true
        }

        return false
    }

    private nonisolated func getSmartAggregatedName(dirName: String, itemCount: Int) -> String {
        let formattedCount = itemCount.formatted()

        // Pattern-based naming for known directories
        switch dirName {
        case "node_modules":
            return "📦 node_modules (\(formattedCount) items)"
        case ".git":
            return "🔧 .git (\(formattedCount) objects)"
        case "venv", ".venv":
            return "🐍 Python venv (\(formattedCount) files)"
        case "vendor":
            return "📚 vendor (\(formattedCount) files)"
        case "Pods":
            return "🎯 CocoaPods (\(formattedCount) files)"
        case "DerivedData":
            return "🔨 DerivedData (\(formattedCount) files)"
        case ".build", ".swiftpm":
            return "🔨 Swift Build (\(formattedCount) files)"
        default:
            if dirName.hasPrefix(".") {
                return "🔒 \(dirName) (\(formattedCount) items)"
            } else if itemCount > 5000 {
                return "📊 \(dirName) (\(formattedCount) items - aggregated)"
            } else {
                return "\(dirName) (\(formattedCount) items)"
            }
        }
    }

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
        // Get the USED capacity, not total capacity
        // This matches what we show in the sidebar and gives accurate progress
        let url = URL(fileURLWithPath: path)

        // Use statfs to get actual used bytes (same as HyperScanner)
        var stat = statfs()
        let result = url.withUnsafeFileSystemRepresentation { pathPtr in
            statfs(pathPtr, &stat)
        }

        if result == 0 {
            let blockSize = Int64(stat.f_bsize)
            let totalBlocks = Int64(stat.f_blocks)
            let freeBlocks = Int64(stat.f_bfree)
            let usedBlocks = totalBlocks - freeBlocks
            let usedBytes = usedBlocks * blockSize
            print("[DiskAnalyzer] Total disk used: \(ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file))")
            return usedBytes
        }

        // Fallback: try to get volume capacity
        do {
            let resourceValues = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            let total = Int64(resourceValues.volumeTotalCapacity ?? 0)
            let available = Int64(resourceValues.volumeAvailableCapacity ?? 0)
            let used = total - available
            print("[DiskAnalyzer] Total disk used (fallback): \(ByteCountFormatter.string(fromByteCount: used, countStyle: .file))")
            return used
        } catch {
            print("[DiskAnalyzer] Error getting disk size: \(error)")
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
        folderTree.removeAll()
        sizeCache.removeAll()
        // Cancel any pending size precalculation tasks
        for (_, task) in sizePrecalculationTasks {
            task.cancel()
        }
        sizePrecalculationTasks.removeAll()
    }

    // Helper function for formatting time intervals
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
}

// MARK: - Supporting Types moved to SharedTypes.swift

