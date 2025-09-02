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
                scanProgress = "Full Disk Access required. Please grant in System Settings > Privacy & Security > Full Disk Access"
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
        // Major system directories to show at root level
        let rootDirectories = [
            "/Applications",
            "/Users", 
            "/System",
            "/Library",
            "/private",
            "/usr",
            "/bin",
            "/sbin",
            "/opt",
            "/Volumes"
        ]
        
        let maxConcurrency = min(ProcessInfo.processInfo.activeProcessorCount * 2, 8)
        var items: [FolderItem] = []
        var activeTasks = 0
        
        return await withTaskGroup(of: FolderItem?.self) { group in
            for dirPath in rootDirectories {
                let url = URL(fileURLWithPath: dirPath)
                
                // Check if directory exists and is accessible
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    continue
                }
                
                // Bound the parallelism
                while activeTasks >= maxConcurrency {
                    if let item = await group.next() {
                        if let validItem = item {
                            items.append(validItem)
                        }
                        activeTasks -= 1
                    }
                }
                
                // Build complete recursive tree for this directory
                group.addTask { [weak self] in
                    await self?.buildFolderWithCompleteChildren(url: url, maxDepth: 3)
                }
                activeTasks += 1
            }
            
            // Collect remaining results
            while let item = await group.next() {
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
            
            // Get immediate children
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
            
            var children: [FolderItem] = []
            var totalSize: Int64 = 0
            var totalItemCount = 0
            
            // Process each child
            for childURL in contents {
                autoreleasepool {
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
                            return
                        }
                        
                        let childIsDirectory = childValues.isDirectory ?? false
                        let childSize: Int64
                        let childItemCount: Int
                        
                        if childIsDirectory {
                            // Recursively calculate for subdirectories (but limit depth)
                            if maxDepth > 0 {
                                if let childItem = await buildFolderWithCompleteChildren(url: childURL, maxDepth: maxDepth - 1) {
                                    children.append(childItem)
                                    totalSize += childItem.size
                                    totalItemCount += childItem.itemCount
                                    
                                    // Store in tree for navigation
                                    await MainActor.run {
                                        self.folderTree[childURL.path] = childItem.children
                                    }
                                }
                            } else {
                                // At max depth, just use disk usage
                                let usage = await directoryDiskUsage(at: childURL)
                                childSize = usage.size
                                childItemCount = usage.itemCount
                                
                                let childItem = FolderItem(
                                    name: childURL.lastPathComponent,
                                    path: childURL.path,
                                    size: childSize,
                                    itemCount: childItemCount,
                                    lastModified: childValues.contentModificationDate ?? Date.distantPast,
                                    isDirectory: true
                                )
                                
                                children.append(childItem)
                                totalSize += childSize
                                totalItemCount += childItemCount
                            }
                        } else {
                            // Regular file
                            childSize = Int64(childValues.totalFileAllocatedSize ?? 0)
                            childItemCount = 1
                            
                            let childItem = FolderItem(
                                name: childURL.lastPathComponent,
                                path: childURL.path,
                                size: childSize,
                                itemCount: childItemCount,
                                lastModified: childValues.contentModificationDate ?? Date.distantPast,
                                isDirectory: false
                            )
                            
                            children.append(childItem)
                            totalSize += childSize
                            totalItemCount += childItemCount
                        }
                        
                    } catch {
                        // Skip inaccessible items
                    }
                }
            }
            
            // Store children in tree for this directory
            await MainActor.run {
                self.folderTree[url.path] = children.sorted { $0.size > $1.size }
            }
            
            var item = FolderItem(
                name: url.lastPathComponent,
                path: url.path,
                size: totalSize,
                itemCount: totalItemCount,
                lastModified: resourceValues.contentModificationDate ?? Date.distantPast,
                isDirectory: true
            )
            
            item.children = children.sorted { $0.size > $1.size }
            
            return item
            
        } catch {
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
                autoreleasepool {
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
                            return
                        }
                        
                        // Skip if we've already seen this resource (hard link deduplication)
                        if let resourceID = resourceValues.fileResourceIdentifier {
                            if seenResourceIDs.contains(resourceID) {
                                return
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
            }
            
            return items.sorted { $0.size > $1.size }
            
        } catch {
            print("Error scanning directory \(path): \(error)")
            return []
        }
    }
    
    private func directoryDiskUsage(at rootURL: URL) async -> DiskUsage {
        return await withTaskGroup(of: DiskUsage.self) { group in
            var totalUsage = DiskUsage()
            
            // Start with the directory enumeration
            group.addTask {
                let seenResourceIDs = NSMutableSet()
                return await enumerateDirectoryRecursive(at: rootURL, seenResourceIDs: seenResourceIDs)
            }
            
            // Collect results
            for await usage in group {
                totalUsage.addSize(usage.size)
                totalUsage.fileCount += usage.itemCount
            }
            
            return totalUsage
        }
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
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else {
                return DiskUsage()
            }
            
            var usage = DiskUsage()
            
            for case let url as URL in enumerator {
                autoreleasepool {
                    do {
                        let resourceValues = try url.resourceValues(forKeys: Set(keys))
                        
                        // Skip symlinks
                        if resourceValues.isSymbolicLink == true {
                            enumerator.skipDescendants()
                            return
                        }
                        
                        // Skip if we've seen this resource (hard link deduplication)
                        if let resourceID = resourceValues.fileResourceIdentifier {
                            if seenResourceIDs.contains(resourceID) {
                                return
                            }
                            seenResourceIDs.add(resourceID)
                        }
                        
                        // Only count regular files for size (directories are counted by their contents)
                        if resourceValues.isRegularFile == true {
                            usage.addSize(Int64(resourceValues.totalFileAllocatedSize ?? 0))
                        }
                        usage.addItem()
                        
                    } catch {
                        // Skip files we can't access
                        enumerator.skipDescendants()
                    }
                }
            }
            
            return usage
        }
    }
    
    private func calculatePercentages() {
        guard totalSize > 0 else { return }
        for i in rootItems.indices {
            rootItems[i].percentage = Double(rootItems[i].size) / Double(totalSize) * 100
        }
    }
    
    private func hasFullDiskAccess() -> Bool {
        // Test by trying to access a protected system directory
        let testPath = "/System/Library/Extensions"
        return FileManager.default.isReadableFile(atPath: testPath)
    }
    
    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
        scanProgress = ""
    }
}