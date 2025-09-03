import Foundation

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
    @Published var scannedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var totalDiskBytes: Int64 = 0
    @Published var totalDiskScannedBytes: Int64 = 0
    @Published var overallProgressPercentage: Double = 0.0
    @Published var externalVolumes: [FolderItem] = []
    
    private var scanTask: Task<Void, Never>?
    private var scanStartTime: Date?
    private var totalFilesProcessed: Int = 0
    private var totalBytesProcessed: Int64 = 0
    private var progressModel = RateModel()
    private var lastProgressUpdate: Date = Date()
    private var seenFileIDs = ShardedFileIDSet()
    private let firmlinkResolver = FirmlinkResolver()
    
    // Complete folder tree for instant navigation
    private var folderTree: [String: [FolderItem]] = [:]
    
    // Pre-calculated directory sizes for instant progress bars
    private var sizeCache: [String: Int64] = [:]
    private var sizePrecalculationTasks: [String: Task<Int64, Never>] = [:]
    
    // Navigate to a path using pre-calculated data
    // Returns true if cached data was found and loaded, false otherwise
    func navigateToPath(_ path: String) -> Bool {
        // Special case: if navigating back to root path and we have root items, use them
        if path == "/" && !rootItems.isEmpty && !isScanning {
            // Already have root data loaded, no need to rescan
            calculatePercentages()
            return true
        }
        
        // Check folder tree cache for other paths
        if let preCalculatedItems = folderTree[path] {
            rootItems = preCalculatedItems
            totalSize = preCalculatedItems.reduce(0) { $0 + $1.size }
            calculatePercentages()
            return true
        }
        return false
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
        seenFileIDs = ShardedFileIDSet()
        
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
            self.seenFileIDs = ShardedFileIDSet()
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
        
        // Filter directories on MainActor
        let filteredDirs = accessibleDirs.filter { fullPath in
            !shouldSkipSystemPath(fullPath) && !firmlinkResolver.isDataSide(fullPath)
        }
            
        // Process accessible directories
        var items: [FolderItem] = []
        let limitedDirs = Array(filteredDirs.prefix(10)) // Limit to avoid overwhelming
            
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
                    
                    // Update progress
                    scannedBytes = totalScannedBytes
                    totalDiskScannedBytes = totalScannedBytes
                    
                    // Calculate overall progress if we have total disk size
                    if totalDiskBytes > 0 {
                        overallProgressPercentage = min(100.0, Double(totalScannedBytes) / Double(totalDiskBytes) * 100.0)
                    }
                }
            }
            
            // Final update
            scanProgressPercentage = 100.0
            totalBytes = totalScannedBytes
            scannedBytes = totalScannedBytes
            totalDiskScannedBytes = totalScannedBytes
            
            // Final overall progress calculation
            if totalDiskBytes > 0 {
                overallProgressPercentage = min(100.0, Double(totalScannedBytes) / Double(totalDiskBytes) * 100.0)
            }
            
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
            
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: path)
                let keys: Set<URLResourceKey> = [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                    .contentModificationDateKey
                ]
                
                for item in contents {
                    let fullPath = path.hasSuffix("/") ? path + item : path + "/" + item
                    let url = URL(fileURLWithPath: fullPath)
                    
                    do {
                        let rv = try url.resourceValues(forKeys: keys)
                        if rv.isSymbolicLink == true { continue }
                        
                        let isDir = rv.isDirectory ?? false
                        var size: Int64 = 0
                        var childChildren: [FolderItem] = []
                        
                        if isDir {
                            // For directories, calculate recursive size
                            size = await DiskAnalyzer.getDirectoryTotalSizeFast(path: fullPath)
                            
                            // Build children recursively - go unlimited depth for full scan
                            if unlimited {
                                childChildren = await DiskAnalyzer.buildDirectoryChildren(path: fullPath, unlimited: true, visitedPaths: currentVisited)
                            }
                        } else if rv.isRegularFile == true {
                            if let t = rv.totalFileAllocatedSize { size = Int64(t) }
                            else if let a = rv.fileAllocatedSize { size = Int64(a) }
                        }
                        
                        var child = FolderItem(
                            name: item,
                            path: fullPath,
                            size: size,
                            isDirectory: isDir,
                            itemCount: isDir ? (childChildren.isEmpty ? 1 : childChildren.count) : 0,
                            lastModified: rv.contentModificationDate ?? Date()
                        )
                        child.children = childChildren
                        children.append(child)
                    } catch {
                        // Skip items that can't be accessed
                        continue
                    }
                }
            } catch {
                // If we can't read the directory, return empty array
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
            for case let url as URL in enumerator {
            do {
                let rv = try url.resourceValues(forKeys: keys)
                if rv.isSymbolicLink == true { continue }
                if rv.isRegularFile == true {
                    // Note: seenFileIDs access moved outside Task.detached to avoid concurrency issues
                    var sz: Int64 = 0
                    if let t = rv.totalFileAllocatedSize { sz = Int64(t) }
                    else if let a = rv.fileAllocatedSize { sz = Int64(a) }
                    processedSize += sz
                    itemsProcessed += 1
                    if itemsProcessed - lastProgressUpdate >= 500 || (sz > 0 && processedSize % (10 * 1024 * 1024) < sz) {
                        lastProgressUpdate = itemsProcessed
                        let currentSize = processedSize
                        let total = max(totalDirectorySize, 1)
                        let progressPercent = min(100.0, Double(currentSize) / Double(total) * 100.0)
                        await MainActor.run {
                            self.scannedBytes = currentSize
                            self.scanProgressPercentage = progressPercent
                        }
                    }
                }
            } catch {
                continue
            }
            if Task.isCancelled { break }
        }
        
        // Final update with exact totals
        let finalSize = totalDirectorySize
        await MainActor.run {
            self.scannedBytes = finalSize
            self.scanProgressPercentage = 100.0
        }
        
        return finalSize
        }.value
    }
    
    private static func getDirectoryTotalSizeFast(path: String) async -> Int64 {
        return await Task.detached {
            var totalSize: Int64 = 0
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey, .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                .fileResourceIdentifierKey
            ]
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                return 0
            }
            let localSeen = ShardedFileIDSet()
            for case let url as URL in enumerator {
                do {
                    let rv = try url.resourceValues(forKeys: keys)
                    if rv.isSymbolicLink == true { continue }
                    if rv.isRegularFile == true {
                        if let id = rv.fileResourceIdentifier as? Data {
                            if !localSeen.insert(id) { continue }
                        }
                        if let t = rv.totalFileAllocatedSize {
                            totalSize += Int64(t)
                        } else if let a = rv.fileAllocatedSize {
                            totalSize += Int64(a)
                        }
                    }
                } catch {
                    continue
                }
            }
            return totalSize
        }.value
    }
    
    private func scanDirectoryContentsSafe(_ path: String) async -> [FolderItem] {
        return await Task.detached {
            var items: [FolderItem] = []
            
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: path)
                let keys: Set<URLResourceKey> = [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                    .contentModificationDateKey
                ]
                
                for item in contents {
                    let fullPath = path.hasSuffix("/") ? path + item : path + "/" + item
                    let url = URL(fileURLWithPath: fullPath)
                    
                    do {
                        let rv = try url.resourceValues(forKeys: keys)
                        if rv.isSymbolicLink == true { continue }
                        
                        let isDir = rv.isDirectory ?? false
                        var size: Int64 = 0
                        
                        if isDir {
                            // For directories, calculate recursive size
                            size = await DiskAnalyzer.getDirectoryTotalSizeFast(path: fullPath)
                        } else if rv.isRegularFile == true {
                            if let t = rv.totalFileAllocatedSize { size = Int64(t) }
                            else if let a = rv.fileAllocatedSize { size = Int64(a) }
                        }
                        
                        var folderItem = FolderItem(
                            name: item,
                            path: fullPath,
                            size: size,
                            isDirectory: isDir,
                            itemCount: isDir ? 1 : 0,
                            lastModified: rv.contentModificationDate ?? Date()
                        )
                        
                        // For directories, get all children - unlimited depth
                        if isDir {
                            folderItem.children = await DiskAnalyzer.buildDirectoryChildren(path: fullPath, unlimited: true, visitedPaths: [])
                        }
                        
                        items.append(folderItem)
                    } catch {
                        // Skip items that can't be accessed
                        continue
                    }
                }
            } catch {
                // If we can't read the directory, return empty array
                return []
            }
            
            return items.sorted()
        }.value
    }
    
    private func shouldSkipSystemPath(_ path: String) -> Bool {
        let skipPaths = [
            "/dev", "/proc", "/sys", "/tmp", "/var/folders",
            "/.Spotlight-V100", "/.fseventsd", "/.Trashes"
        ]
        return skipPaths.contains { path.hasPrefix($0) }
    }
    
    private func getTotalDiskSize(path: String) -> Int64 {
        // Try URL resource values first
        do {
            let url = URL(fileURLWithPath: path)
            let resourceValues = try url.resourceValues(forKeys: [.volumeTotalCapacityKey])
            if let totalCapacity = resourceValues.volumeTotalCapacity, totalCapacity > 0 {
                print("Got total disk size via URL method: \(totalCapacity) bytes")
                return Int64(totalCapacity)
            }
        } catch {
            print("Error getting disk size with URL method: \(error)")
        }
        
        // Fallback to FileManager method
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            if let totalSize = attributes[.systemSize] as? Int64, totalSize > 0 {
                print("Got total disk size via FileManager method: \(totalSize) bytes")
                return totalSize
            }
        } catch {
            print("Error getting disk size with FileManager method: \(error)")
        }
        
        // If both methods fail, return a reasonable default based on common disk sizes
        // This prevents showing "Zero KB" 
        print("Warning: Could not determine disk size, using fallback estimate")
        return 1_000_000_000_000 // 1TB fallback estimate
    }
    
    private func hasFullDiskAccess() -> Bool {
        // Simple check - try to access a protected directory
        let testPath = "/Library/Application Support/com.apple.TCC"
        return FileManager.default.isReadableFile(atPath: testPath)
    }
    
    func scanExternalVolumes() async {
        // Get mounted volumes using Task.detached
        let volumes = await Task.detached {
            let volumeURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ], options: [.skipHiddenVolumes]) ?? []
            
            var volumes: [FolderItem] = []
            
            for volumeURL in volumeURLs {
            // Skip the main system volume and system-only volumes
            if volumeURL.path == "/" || volumeURL.path.hasPrefix("/System") { 
                continue 
            }
            
            do {
                let resourceValues = try volumeURL.resourceValues(forKeys: [
                    .volumeNameKey,
                    .volumeTotalCapacityKey,
                    .volumeAvailableCapacityKey,
                    .volumeAvailableCapacityForImportantUsageKey
                ])
                
                let volumeName = resourceValues.volumeName ?? volumeURL.lastPathComponent
                let totalCapacity = Int64(resourceValues.volumeTotalCapacity ?? 0)
                
                // Skip volumes with 0 capacity or very small capacities (likely system volumes)
                guard totalCapacity > 1024 * 1024 else { continue }
                
                // Check if it's an external volume by checking the path
                let isExternal = volumeURL.path.hasPrefix("/Volumes/")
                
                let volumeItem = FolderItem(
                    name: volumeName,
                    path: volumeURL.path,
                    size: totalCapacity,
                    isDirectory: true,
                    itemCount: 1,
                    lastModified: Date()
                )
                
                volumes.append(volumeItem)
                print("Found volume: \(volumeName) at \(volumeURL.path) - \(totalCapacity) bytes, external: \(isExternal)")
                
            } catch {
                print("Error getting volume info for \(volumeURL.path): \(error)")
                continue
            }
            }
            
            print("Total external volumes found: \(volumes.count)")
            return volumes
        }.value
        
        // Update on MainActor
        externalVolumes = volumes
    }
}
