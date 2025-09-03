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
            
            for dirPath in accessibleDirs.prefix(10) { // Limit to avoid overwhelming
                await MainActor.run { [weak self] in
                    self?.scanProgress = "Analyzing \(URL(fileURLWithPath: dirPath).lastPathComponent)..."
                }
                
                if let item = await buildFolderItemSafely(path: dirPath) {
                    items.append(item)
                }
            }
            
            return items.sorted()
            
        } catch {
            print("Error scanning root: \(error)")
            return []
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
    
    private func calculateDirectorySize(path: String) async -> Int64 {
        var totalSize: Int64 = 0
        
        guard let enumerator = FileManager.default.enumerator(atPath: path) else {
            return 0
        }
        
        var processedItems = 0
        while let item = enumerator.nextObject() as? String {
            let itemPath = path.hasSuffix("/") ? "\(path)\(item)" : "\(path)/\(item)"
            
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: itemPath)
                if let size = attributes[.size] as? Int64 {
                    totalSize += size
                }
            } catch {
                // Skip files we can't access
                continue
            }
            
            processedItems += 1
            
            // Update progress periodically and yield control
            if processedItems % 1000 == 0 {
                let currentCount = processedItems // Capture for concurrent access
                let folderName = URL(fileURLWithPath: path).lastPathComponent
                await MainActor.run { [weak self] in
                    self?.scanProgress = "Analyzing \(folderName)... (\(currentCount) items)"
                }
                await Task.yield() // Allow other tasks to run
            }
            
            // Limit processing time to avoid blocking
            if processedItems > 50000 {
                break
            }
        }
        
        return totalSize
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
    
    private func hasFullDiskAccess() -> Bool {
        // Simple check - try to access a protected directory
        let testPath = "/Library/Application Support/com.apple.TCC"
        return FileManager.default.isReadableFile(atPath: testPath)
    }
    
    func scanExternalVolumes() async {
        // Get mounted volumes
        let volumeURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ], options: .skipHiddenVolumes) ?? []
        
        var volumes: [FolderItem] = []
        
        for volumeURL in volumeURLs {
            // Skip the main system volume
            if volumeURL.path == "/" { continue }
            
            do {
                let resourceValues = try volumeURL.resourceValues(forKeys: [
                    .volumeNameKey,
                    .volumeTotalCapacityKey,
                    .volumeAvailableCapacityKey
                ])
                
                let volumeName = resourceValues.volumeName ?? volumeURL.lastPathComponent
                let totalCapacity = Int64(resourceValues.volumeTotalCapacity ?? 0)
                
                let volumeItem = FolderItem(
                    name: volumeName,
                    path: volumeURL.path,
                    size: totalCapacity,
                    isDirectory: true,
                    itemCount: 1,
                    lastModified: Date()
                )
                
                volumes.append(volumeItem)
            } catch {
                print("Error getting volume info for \(volumeURL): \(error)")
            }
        }
        
        // Capture the final volumes array before passing to MainActor
        let finalVolumes = volumes
        await MainActor.run { [finalVolumes] in
            self.externalVolumes = finalVolumes
        }
    }
}