import Foundation

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
    private var totalItemsToScan: Int = 0
    private var itemsScanned: Int = 0
    private var directoriesCompleted: Int = 0
    private var totalDirectories: Int = 0
    
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
        itemsScanned = 0
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
            self.directoriesCompleted = 0
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
        
        // Set total directories for progress tracking
        await MainActor.run {
            self.totalDirectories = rootDirectories.count
        }
        
        // Use actor-isolated approach for thread safety
        return await withTaskGroup(of: FolderItem?.self) { group in
            var items: [FolderItem] = []
            
            for dirPath in rootDirectories {
                let url = URL(fileURLWithPath: dirPath)
                
                // Check if directory exists and is accessible
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    await MainActor.run {
                        self.directoriesCompleted += 1
                        self.updateProgress()
                    }
                    continue
                }
                
                // Build complete recursive tree for this directory
                group.addTask { [weak self] in
                    let result = await self?.buildFolderWithCompleteChildren(url: url, maxDepth: 3)
                    
                    // Update progress after completing each directory
                    await MainActor.run {
                        self?.directoriesCompleted += 1
                        self?.updateProgress()
                    }
                    
                    return result
                }
            }
            
            // Collect all results
            for await item in group {
                if let validItem = item {
                    items.append(validItem)
                }
            }
            
            return items.sorted { $0.size > $1.size }
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
                    .totalFileAllocatedSizeKey,
                    .contentModificationDateKey
                ],
                options: [.skipsPackageDescendants]
            )
            
            // Process immediate children for display
            var children: [FolderItem] = []
            let totalChildren = contents.count
            var processedChildren = 0
            
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
                    processedChildren += 1
                    
                    // Update progress every 50 items or if it's a major directory
                    if processedChildren % 50 == 0 || url.path.hasPrefix("/System") || url.path.hasPrefix("/Users") {
                        await MainActor.run {
                            self.scanProgress = "Analyzing \(url.lastPathComponent): \(processedChildren)/\(totalChildren) items..."
                        }
                    }
                    
                } catch {
                    // Skip inaccessible items
                    processedChildren += 1
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
    
    private func directoryDiskUsage(at rootURL: URL) async -> DiskUsage {
        // Direct enumeration without task groups to avoid async issues
        let seenResourceIDs = NSMutableSet()
        return await enumerateDirectoryRecursive(at: rootURL, seenResourceIDs: seenResourceIDs)
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
                        
                        // Only count regular files for size (directories are counted by their contents)
                        if resourceValues.isRegularFile == true {
                            let allocatedSize = resourceValues.totalFileAllocatedSize ?? 0
                            usage.addSize(Int64(allocatedSize))
                        }
                        
                    } catch {
                        // Skip files we can't access - return from autoreleasepool
                        return
                    }
                }
            }
            
            return usage
        }
    }
    
    private func updateProgress() {
        guard totalDirectories > 0 else { return }
        
        let progressPercent = Double(directoriesCompleted) / Double(totalDirectories) * 100.0
        scanProgressPercentage = min(progressPercent, 100.0)
        
        // Update progress message
        if directoriesCompleted < totalDirectories {
            scanProgress = "Analyzing \(directoriesCompleted)/\(totalDirectories) directories..."
        } else {
            scanProgress = "Finalizing analysis..."
        }
        
        // Calculate ETA
        if let startTime = scanStartTime, directoriesCompleted > 0 {
            let elapsed = Date().timeIntervalSince(startTime)
            let rate = Double(directoriesCompleted) / elapsed
            
            if rate > 0 && directoriesCompleted < totalDirectories {
                let remaining = Double(totalDirectories - directoriesCompleted) / rate
                
                if remaining > 60 {
                    let minutes = Int(remaining / 60)
                    estimatedTimeRemaining = "\(minutes) min remaining"
                } else if remaining > 1 {
                    estimatedTimeRemaining = "\(Int(remaining)) sec remaining"
                } else {
                    estimatedTimeRemaining = "Almost done..."
                }
            } else {
                estimatedTimeRemaining = ""
            }
        }
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