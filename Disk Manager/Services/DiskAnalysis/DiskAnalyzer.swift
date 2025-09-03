import Foundation

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
        }
        
        // Enumerate accessible top-level directories with better error handling
        return await scanRootDirectoriesSafely()
    }
    
    private func scanRootDirectoriesSafely() async -> [FolderItem] {
        // Try to enumerate "/" first to get all directories
        do {
            let rootContents = try FileManager.default.contentsOfDirectory(atPath: "/")
            var accessibleDirs: [String] = []
            
            // Check which directories are actually accessible
            for item in rootContents {
                let fullPath = "/" + item
                var isDirectory: ObjCBool = false
                
                if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) && 
                   isDirectory.boolValue &&
                   FileManager.default.isReadableFile(atPath: fullPath) &&
                   !shouldSkipSystemPath(fullPath) {
                    
                    accessibleDirs.append(fullPath)
                }
            }
            
            // Process accessible directories
            var items: [FolderItem] = []
            let limitedDirs = Array(accessibleDirs.prefix(10)) // Limit to avoid overwhelming
            
            // PRE-CALCULATE: Start calculating sizes for all directories in parallel
            await MainActor.run { [weak self] in
                self?.scanProgress = "Pre-calculating directory sizes..."
                self?.scanProgressPercentage = 0.0
            }
            
            // Start parallel size calculations for all directories
            await withTaskGroup(of: Void.self) { group in
                for dirPath in limitedDirs {
                    group.addTask { [weak self] in
                        if self?.sizeCache[dirPath] == nil {
                            let size = await self?.getDirectoryTotalSizeFast(path: dirPath) ?? 0
                            await MainActor.run {
                                self?.sizeCache[dirPath] = size
                            }
                        }
                    }
                }
            }
            
            await MainActor.run { [weak self] in
                self?.scanProgress = "Starting analysis..."
            }
            
            var totalScannedBytes: Int64 = 0
            
            for (index, dirPath) in limitedDirs.enumerated() {
                // Get next directory for parallel pre-calculation (if any)
                let nextPath = index + 1 < limitedDirs.count ? limitedDirs[index + 1] : nil
                
                await MainActor.run { [weak self] in
                    self?.scanProgress = "Analyzing \(URL(fileURLWithPath: dirPath).lastPathComponent)..."
                    self?.scanProgressPercentage = Double(index) / Double(limitedDirs.count) * 100.0
                }
                
                if let item = await buildFolderItemSafelyWithCache(path: dirPath, nextPath: nextPath) {
                    items.append(item)
                    totalScannedBytes += item.size
                    
                    // Capture values for concurrent access
                    let currentScannedBytes = totalScannedBytes
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        self.scannedBytes = currentScannedBytes
                        self.totalDiskScannedBytes = currentScannedBytes
                        
                        // Calculate overall progress if we have total disk size
                        if self.totalDiskBytes > 0 {
                            self.overallProgressPercentage = min(100.0, Double(currentScannedBytes) / Double(self.totalDiskBytes) * 100.0)
                        }
                    }
                }
            }
            
            // Final update - capture values for concurrent access
            let finalTotalBytes = totalScannedBytes
            let finalScannedBytes = totalScannedBytes
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.scanProgressPercentage = 100.0
                self.totalBytes = finalTotalBytes
                self.scannedBytes = finalScannedBytes
                self.totalDiskScannedBytes = finalScannedBytes
                
                // Final overall progress calculation
                if self.totalDiskBytes > 0 {
                    self.overallProgressPercentage = min(100.0, Double(finalScannedBytes) / Double(self.totalDiskBytes) * 100.0)
                }
            }
            
            return items.sorted()
            
        } catch {
            print("Error scanning root: \(error)")
            return []
        }
    }
    
    private func buildFolderItemSafelyWithCache(path: String, nextPath: String?) async -> FolderItem? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes[.size] as? Int64) ?? 0
            let modificationDate = (attributes[.modificationDate] as? Date) ?? Date()
            
            // For directories, use cached size or calculate with next path for parallel pre-calc
            var totalSize = size
            let itemCount = 1
            
            if let type = attributes[.type] as? FileAttributeType, type == .typeDirectory {
                // Use cache-aware calculation with next path for parallel processing
                totalSize = await calculateDirectorySize(path: path, nextPath: nextPath)
            }
            
            return FolderItem(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                size: totalSize,
                isDirectory: true,
                itemCount: itemCount,
                lastModified: modificationDate
            )
        } catch {
            print("Error processing \(path): \(error)")
            return nil
        }
    }
    
    private func buildFolderItemSafely(path: String) async -> FolderItem? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes[.size] as? Int64) ?? 0
            let modificationDate = (attributes[.modificationDate] as? Date) ?? Date()
            
            // For directories, calculate total size recursively (simplified)
            var totalSize = size
            let itemCount = 1
            
            if let type = attributes[.type] as? FileAttributeType, type == .typeDirectory {
                // Simple directory size calculation
                totalSize = await calculateDirectorySize(path: path)
            }
            
            return FolderItem(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                size: totalSize,
                isDirectory: true,
                itemCount: itemCount,
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
            
            totalDirectorySize = await getDirectoryTotalSizeFast(path: path)
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
                let size = await self?.getDirectoryTotalSizeFast(path: capturedNextPath) ?? 0
                await MainActor.run { [weak self] in
                    self?.sizeCache[capturedNextPath] = size
                    self?.sizePrecalculationTasks[capturedNextPath] = nil
                }
                return size
            }
        }
        
        guard let enumerator = FileManager.default.enumerator(atPath: path) else {
            return totalDirectorySize
        }
        
        var processedSize: Int64 = 0
        var itemsProcessed = 0
        var lastProgressUpdate = 0
        
        // STEP 3: Detailed analysis with accurate progress bar
        while let item = enumerator.nextObject() as? String {
            let itemPath = path.hasSuffix("/") ? "\(path)\(item)" : "\(path)/\(item)"
            
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: itemPath)
                if let size = attributes[.size] as? Int64 {
                    processedSize += size
                    itemsProcessed += 1
                    
                    // Update progress every 500 items or 10MB for more frequent updates
                    if itemsProcessed - lastProgressUpdate >= 500 || processedSize % (10 * 1024 * 1024) < size {
                        lastProgressUpdate = itemsProcessed
                        let currentSize = processedSize
                        let total = totalDirectorySize // Capture for concurrent access
                        let progressPercent = total > 0 ? min(100.0, Double(currentSize) / Double(total) * 100.0) : 0.0
                        
                        await MainActor.run { [weak self, currentSize, progressPercent] in
                            self?.scannedBytes = currentSize
                            self?.scanProgressPercentage = progressPercent
                        }
                        await Task.yield()
                    }
                }
            } catch {
                continue
            }
            
            if Task.isCancelled {
                break
            }
        }
        
        // Final update with exact totals
        let finalSize = totalDirectorySize // Capture for concurrent access
        await MainActor.run { [weak self, finalSize] in
            self?.scannedBytes = finalSize
            self?.scanProgressPercentage = 100.0
        }
        
        return finalSize
    }
    
    private func getDirectoryTotalSizeFast(path: String) async -> Int64 {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var totalSize: Int64 = 0
                
                // Use URL-based enumeration which is faster for size calculation
                guard let enumerator = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: path),
                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                    options: [.skipsPackageDescendants],
                    errorHandler: { _, _ in return true }
                ) else {
                    continuation.resume(returning: 0)
                    return
                }
                
                for case let url as URL in enumerator {
                    do {
                        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        if resourceValues.isRegularFile == true, let fileSize = resourceValues.fileSize {
                            totalSize += Int64(fileSize)
                        }
                    } catch {
                        continue
                    }
                }
                
                continuation.resume(returning: totalSize)
            }
        }
    }
    
    private func scanDirectoryContentsSafe(_ path: String) async -> [FolderItem] {
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: path)
            var items: [FolderItem] = []
            
            for item in contents {
                let itemPath = path.hasSuffix("/") ? "\(path)\(item)" : "\(path)/\(item)"
                
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: itemPath)
                    let size = (attributes[.size] as? Int64) ?? 0
                    let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
                    let modificationDate = (attributes[.modificationDate] as? Date) ?? Date()
                    
                    let folderItem = FolderItem(
                        name: item,
                        path: itemPath,
                        size: size,
                        isDirectory: isDirectory,
                        itemCount: isDirectory ? 1 : 0,
                        lastModified: modificationDate
                    )
                    
                    items.append(folderItem)
                } catch {
                    // Skip files we can't access
                    continue
                }
            }
            
            return items.sorted()
        } catch {
            print("Error scanning directory \(path): \(error)")
            return []
        }
    }
    
    private func shouldSkipSystemPath(_ path: String) -> Bool {
        let skipPaths = [
            "/dev", "/proc", "/sys", "/tmp", "/var/folders",
            "/.Spotlight-V100", "/.fseventsd", "/.Trashes"
        ]
        return skipPaths.contains { path.hasPrefix($0) }
    }
    
    private func getTotalDiskSize(path: String) -> Int64 {
        do {
            let url = URL(fileURLWithPath: path)
            let resourceValues = try url.resourceValues(forKeys: [.volumeTotalCapacityKey])
            if let totalCapacity = resourceValues.volumeTotalCapacity {
                return Int64(totalCapacity)
            }
        } catch {
            print("Error getting disk size with URL method: \(error)")
        }
        
        // Fallback to FileManager method
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            if let totalSize = attributes[.systemSize] as? Int64 {
                return totalSize
            }
        } catch {
            print("Error getting disk size with FileManager method: \(error)")
        }
        
        return 0
    }
    
    private func hasFullDiskAccess() -> Bool {
        // Simple check - try to access a protected directory
        let testPath = "/Library/Application Support/com.apple.TCC"
        return FileManager.default.isReadableFile(atPath: testPath)
    }
    
    func scanExternalVolumes() async {
        // Get mounted volumes with better error handling
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
        
        // Capture the final volumes array before passing to MainActor
        let finalVolumes = volumes
        await MainActor.run { [finalVolumes] in
            self.externalVolumes = finalVolumes
        }
    }
}