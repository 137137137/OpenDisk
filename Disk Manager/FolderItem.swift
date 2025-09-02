import Foundation

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

class DiskAnalyzer: ObservableObject {
    @Published var rootItems: [FolderItem] = []
    @Published var isScanning: Bool = false
    @Published var scanProgress: String = ""
    @Published var scanProgressPercentage: Double = 0.0
    @Published var estimatedTimeRemaining: String = ""
    @Published var totalSize: Int64 = 0
    
    private var scanTask: Task<Void, Never>?
    private var scanStartTime: Date?
    private var totalFilesProcessed: Int = 0
    private var totalBytesProcessed: Int64 = 0
    private var estimatedTotalFiles: Int = 0
    private var lastProgressUpdate: Date = Date()
    private var filesProcessedSinceLastUpdate: Int = 0
    
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
        scanStartTime = Date()
        
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
        
        scanTask = Task {
            let items = await performScanWithProgress(path: scanPath)
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
            self.estimatedTotalFiles = 0
            self.lastProgressUpdate = Date()
        }
        
        // Major system directories to show at root level
        var rootDirectories = [
            "/Applications",
            "/Users",
            "/System", 
            "/Library",
            "/usr",
            "/opt",
            "/private"
        ]
        
        // Add external volumes from /Volumes (but not /Volumes itself)
        if let volumeContents = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for volume in volumeContents {
                let volumePath = "/Volumes/\(volume)"
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: volumePath, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    rootDirectories.append(volumePath)
                }
            }
        }
        
        // Create immutable copy to avoid capture issues
        let directoriesToScan = rootDirectories
        
        // Use maximum parallelism with bounded concurrency for optimal performance
        let maxConcurrency = max(ProcessInfo.processInfo.activeProcessorCount * 2, 8)
        
        return await withTaskGroup(of: FolderItem?.self) { group in
            var items: [FolderItem] = []
            var activeTasks = 0
            var directoryIndex = 0
            
            // Start initial batch of tasks
            while directoryIndex < directoriesToScan.count && activeTasks < maxConcurrency {
                let dirPath = directoriesToScan[directoryIndex]
                let url = URL(fileURLWithPath: dirPath)
                
                // Check if directory exists and is accessible
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                    group.addTask { [weak self] in
                        return await self?.buildFolderWithCompleteChildrenFast(url: url)
                    }
                    activeTasks += 1
                }
                directoryIndex += 1
            }
            
            // Process results and spawn new tasks as they complete
            for await item in group {
                if let validItem = item {
                    items.append(validItem)
                }
                activeTasks -= 1
                
                // Start next task if available
                if directoryIndex < directoriesToScan.count {
                    let dirPath = directoriesToScan[directoryIndex]
                    let url = URL(fileURLWithPath: dirPath)
                    
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                        group.addTask { [weak self] in
                            return await self?.buildFolderWithCompleteChildrenFast(url: url)
                        }
                        activeTasks += 1
                    }
                    directoryIndex += 1
                }
            }
            
            return items.sorted { $0.size > $1.size }
        }
    }
    
    private func buildFolderWithCompleteChildrenFast(url: URL) async -> FolderItem? {
        // High-performance directory analysis with parallel subdirectory processing
        return await buildFolderWithParallelChildren(url: url, depth: 0, maxDepth: 2)
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
                    .totalFileAllocatedSizeKey,
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
                        .totalFileAllocatedSizeKey,
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
                        childSize = Int64(childValues.totalFileAllocatedSize ?? 0)
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
        let rootURL = URL(fileURLWithPath: path)
        
        // Check if we can access this directory
        guard FileManager.default.isReadableFile(atPath: path) else {
            print("No read access to \(path)")
            return []
        }
        
        do {
            // Get immediate children
            let contents = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .totalFileAllocatedSizeKey,
                    .contentModificationDateKey,
                    .fileResourceIdentifierKey
                ],
                options: [.skipsPackageDescendants]
            )
            
            var items: [FolderItem] = []
            let seenResourceIDs = NSMutableSet()
            
            for url in contents {
                do {
                    let resourceValues = try url.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .totalFileAllocatedSizeKey,
                        .contentModificationDateKey,
                        .fileResourceIdentifierKey
                    ])
                    
                    // Skip symlinks
                    if resourceValues.isSymbolicLink == true {
                        continue
                    }
                    
                    // Skip if we've already seen this resource (hard link deduplication)
                    if let resourceID = resourceValues.fileResourceIdentifier {
                        if seenResourceIDs.contains(resourceID) {
                            continue
                        }
                        seenResourceIDs.add(resourceID)
                    }
                    
                    let isDirectory = resourceValues.isDirectory ?? false
                    let size: Int64
                    let itemCount: Int
                    
                    if isDirectory {
                        let diskUsage = await directoryDiskUsage(at: url)
                        size = diskUsage.size
                        itemCount = diskUsage.itemCount
                    } else {
                        size = Int64(resourceValues.totalFileAllocatedSize ?? 0)
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
                    // Skip files we can't access
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
                    .totalFileAllocatedSizeKey,
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
                    
                    for await batchResult in group {
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
                .totalFileAllocatedSizeKey,
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
                childSize = Int64(childValues.totalFileAllocatedSize ?? 0)
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
        // Direct enumeration without task groups to avoid async issues
        let seenResourceIDs = NSMutableSet()
        return await enumerateDirectoryRecursive(at: rootURL, seenResourceIDs: seenResourceIDs)
    }
    
    private func directoryDiskUsageFast(at rootURL: URL) async -> DiskUsage {
        // Optimized enumeration with reduced progress updates for speed
        let seenResourceIDs = NSMutableSet()
        return await enumerateDirectoryRecursiveFast(at: rootURL, seenResourceIDs: seenResourceIDs)
    }
    
    private func enumerateDirectoryRecursive(at rootURL: URL, seenResourceIDs: NSMutableSet) async -> DiskUsage {
        return autoreleasepool {
            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .fileResourceIdentifierKey
            ]
            
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [] // Include everything like baobab - no skipping
            ) else {
                return DiskUsage()
            }
            
            var usage = DiskUsage()
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
                        
                        // Skip if we've seen this resource (hard link deduplication)
                        if let resourceID = resourceValues.fileResourceIdentifier {
                            if seenResourceIDs.contains(resourceID) {
                                return
                            }
                            seenResourceIDs.add(resourceID)
                        }
                        
                        // Count all items (files and directories)
                        usage.addItem()
                        localFilesProcessed += 1
                        
                        // Only count regular files for size (directories are counted by their contents)
                        if resourceValues.isRegularFile == true {
                            let allocatedSize = resourceValues.totalFileAllocatedSize ?? 0
                            usage.addSize(Int64(allocatedSize))
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
                        // Skip files we can't access - return from autoreleasepool
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
    }
    
    private func enumerateDirectoryRecursiveFast(at rootURL: URL, seenResourceIDs: NSMutableSet) async -> DiskUsage {
        return autoreleasepool {
            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .fileResourceIdentifierKey
            ]
            
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [] // Include everything like baobab - no skipping
            ) else {
                return DiskUsage()
            }
            
            var usage = DiskUsage()
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
                        
                        // Skip if we've seen this resource (hard link deduplication)
                        if let resourceID = resourceValues.fileResourceIdentifier {
                            if seenResourceIDs.contains(resourceID) {
                                return
                            }
                            seenResourceIDs.add(resourceID)
                        }
                        
                        // Count all items (files and directories)
                        usage.addItem()
                        localFilesProcessed += 1
                        
                        // Only count regular files for size (directories are counted by their contents)
                        if resourceValues.isRegularFile == true {
                            let allocatedSize = resourceValues.totalFileAllocatedSize ?? 0
                            usage.addSize(Int64(allocatedSize))
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
    }
    
    private func updateDynamicProgress(currentPath: String) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastProgressUpdate)
        
        // Dynamic estimation based on file processing rate
        if elapsed > 0.5 && totalFilesProcessed > 0 { // Update every 0.5 seconds minimum
            let filesPerSecond = Double(filesProcessedSinceLastUpdate) / elapsed
            
            // Adaptive estimation: start conservative, adjust based on actual rate
            if estimatedTotalFiles == 0 {
                // Initial estimate based on processing rate
                estimatedTotalFiles = max(totalFilesProcessed * 50, 10000) // Conservative start
            } else if filesPerSecond > 0 {
                // Adjust estimate based on current directory
                let pathDepth = currentPath.components(separatedBy: "/").count
                let estimateMultiplier = pathDepth > 4 ? 2.0 : 1.5 // Deep paths likely have more files
                
                let newEstimate = Int(Double(totalFilesProcessed) * estimateMultiplier)
                estimatedTotalFiles = max(estimatedTotalFiles, newEstimate)
            }
            
            // Calculate progress percentage
            let progressPercent = min(Double(totalFilesProcessed) / Double(estimatedTotalFiles) * 100.0, 95.0)
            scanProgressPercentage = progressPercent
            
            // Update progress message with current location and file count
            let pathComponent = URL(fileURLWithPath: currentPath).lastPathComponent
            scanProgress = "Analyzing \(pathComponent): \(formatFileCount(totalFilesProcessed)) files (\(formatBytes(totalBytesProcessed)))"
            
            // Calculate ETA based on file processing rate
            if let startTime = scanStartTime, totalFilesProcessed > 100 {
                let totalElapsed = now.timeIntervalSince(startTime)
                let overallRate = Double(totalFilesProcessed) / totalElapsed
                
                if overallRate > 0 {
                    let remainingFiles = estimatedTotalFiles - totalFilesProcessed
                    let remainingTime = Double(remainingFiles) / overallRate
                    
                    if remainingTime > 120 {
                        let minutes = Int(remainingTime / 60)
                        estimatedTimeRemaining = "~\(minutes) min remaining"
                    } else if remainingTime > 10 {
                        estimatedTimeRemaining = "~\(Int(remainingTime)) sec remaining"
                    } else {
                        estimatedTimeRemaining = "Almost done..."
                    }
                } else {
                    estimatedTimeRemaining = ""
                }
            }
            
            // Reset for next update
            filesProcessedSinceLastUpdate = 0
            lastProgressUpdate = now
        }
        
        filesProcessedSinceLastUpdate += 1
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
}