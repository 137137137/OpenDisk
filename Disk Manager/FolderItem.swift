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
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: itemCount)) ?? "0"
    }
    
    var relativeModified: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastModified, relativeTo: Date())
    }
    
    static func < (lhs: FolderItem, rhs: FolderItem) -> Bool {
        lhs.size > rhs.size // Sort by size descending
    }
}

@MainActor
class DiskAnalyzer: ObservableObject {
    @Published var rootItems: [FolderItem] = []
    @Published var isScanning: Bool = false
    @Published var scanProgress: String = ""
    @Published var totalSize: Int64 = 0
    @Published var scanProgressPercentage: Double = 0.0
    @Published var estimatedTimeRemaining: String = ""
    
    private var scanTask: Task<Void, Never>?
    private var scanStartTime: Date?
    private var totalItemsToScan: Int = 0
    private var itemsScanned: Int = 0
    
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
        // First, estimate the number of items we'll scan
        await MainActor.run {
            self.scanProgress = "Estimating scan size..."
        }
        
        let itemCount = await Self.estimateItemCount(path: path)
        
        await MainActor.run {
            self.totalItemsToScan = itemCount
            self.scanProgress = "Scanning \(itemCount) items..."
        }
        
        // Now perform the actual scan with progress updates
        let analyzer = self
        return await Self.scanDirectoryContentsWithProgress(path) { @MainActor @Sendable current, currentItem in
            analyzer.itemsScanned = current
            
            if analyzer.totalItemsToScan > 0 {
                analyzer.scanProgressPercentage = (Double(current) / Double(analyzer.totalItemsToScan)) * 100.0
            }
            
            analyzer.scanProgress = "Scanning \(currentItem)"
            
            // Calculate ETA
            if let startTime = analyzer.scanStartTime, current > 0 {
                let elapsed = Date().timeIntervalSince(startTime)
                let rate = Double(current) / elapsed
                let remaining = Double(analyzer.totalItemsToScan - current)
                let eta = remaining / rate
                
                if eta > 0 && eta < 3600 { // Only show if less than 1 hour
                    analyzer.estimatedTimeRemaining = String(format: "%.0fs remaining", eta)
                }
            }
        }
    }
    
    private func hasFullDiskAccess() -> Bool {
        // Test if we can access a system directory that requires full disk access
        let testURL = URL(fileURLWithPath: "/Library/Application Support")
        
        do {
            _ = try FileManager.default.contentsOfDirectory(at: testURL, includingPropertiesForKeys: nil)
            return true
        } catch {
            return false
        }
    }
    
    private func calculatePercentages() {
        guard totalSize > 0 else { return }
        for i in rootItems.indices {
            rootItems[i].percentage = Double(rootItems[i].size) / Double(totalSize) * 100
        }
    }
    
    private func performScan(path: String) async -> [FolderItem] {
        return await withCheckedContinuation { continuation in
            Task.detached {
                let items = await DiskAnalyzer.scanDirectoryContentsSafe(path)
                continuation.resume(returning: items)
            }
        }
    }
    
    private static func estimateItemCount(path: String) async -> Int {
        return await withCheckedContinuation { continuation in
            Task.detached {
                let count = await Self.quickEstimateItemCount(path: path)
                continuation.resume(returning: count)
            }
        }
    }
    
    private static func quickEstimateItemCount(path: String) async -> Int {
        let rootURL = URL(fileURLWithPath: path)
        var estimatedCount = 0
        
        if path == "/" {
            // For root, estimate based on major directories
            let majorDirs = ["/Applications", "/Users", "/System", "/Library", "/private"]
            for dirPath in majorDirs {
                estimatedCount += await quickCountItems(at: URL(fileURLWithPath: dirPath), maxDepth: 2)
            }
        } else {
            estimatedCount = await quickCountItems(at: rootURL, maxDepth: 3)
        }
        
        return max(estimatedCount, 10) // Minimum estimate
    }
    
    private static func quickCountItems(at url: URL, maxDepth: Int) async -> Int {
        guard maxDepth > 0 else { return 0 }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            
            var count = contents.count
            
            // For directories, add a quick sample of their contents
            for childURL in contents.prefix(20) { // Limit to first 20 items for speed
                do {
                    let values = try childURL.resourceValues(forKeys: [.isDirectoryKey])
                    if values.isDirectory == true {
                        count += await quickCountItems(at: childURL, maxDepth: maxDepth - 1)
                    }
                } catch {
                    continue
                }
            }
            
            return count
        } catch {
            return 0
        }
    }
    
    private static func scanDirectoryContentsWithProgress(
        _ path: String, 
        progressCallback: @escaping @MainActor @Sendable (Int, String) -> Void
    ) async -> [FolderItem] {
        let rootURL = URL(fileURLWithPath: path)
        
        if path == "/" {
            return await buildRootDirectoryItemsWithProgress(progressCallback: progressCallback)
        } else {
            return await buildDirectoryTreeWithProgress(at: rootURL, progressCallback: progressCallback)
        }
    }
    
    private static func scanDirectoryContentsSafe(_ path: String) async -> [FolderItem] {
        // Use high-performance bounded parallel scanning
        let rootURL = URL(fileURLWithPath: path)
        return await boundedParallelScan(rootURL: rootURL)
    }
    
    private static func buildCompleteDirectoryTree(at rootURL: URL) -> [FolderItem] {
        let fileManager = FileManager.default
        
        // Special handling for root directory
        if rootURL.path == "/" {
            return buildRootDirectoryItems()
        }
        
        // Get immediate children first
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
            .nameKey
        ]
        
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
            
            var items: [FolderItem] = []
            var directoryItems: [FolderItem] = []
            var fileItems: [FolderItem] = []
            
            // First pass: collect all items and calculate directory sizes
            for url in contents {
                if let baseItem = Self.createBaseItem(from: url, keys: keys) {
                    if baseItem.isDirectory {
                        // Calculate actual size recursively for this directory
                        let (totalSize, totalCount) = Self.calculateDirectorySizeDeep(url.path)
                        
                        let directoryItem = FolderItem(
                            name: baseItem.name,
                            path: baseItem.path,
                            size: totalSize,
                            itemCount: totalCount,
                            lastModified: baseItem.lastModified,
                            isDirectory: true
                        )
                        directoryItems.append(directoryItem)
                    } else {
                        fileItems.append(baseItem)
                    }
                }
            }
            
            // Return combined list with directories first, then files
            items = directoryItems + fileItems
            return items
            
        } catch {
            print("Error building directory tree for \(rootURL.path): \(error)")
            return []
        }
    }
    
    private static func buildRootDirectoryItems() -> [FolderItem] {
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
        
        var items: [FolderItem] = []
        let fileManager = FileManager.default
        
        for dirPath in rootDirectories {
            let url = URL(fileURLWithPath: dirPath)
            
            // Check if directory exists and is accessible
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: dirPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            
            do {
                let attributes = try fileManager.attributesOfItem(atPath: dirPath)
                let modDate = attributes[.modificationDate] as? Date ?? Date()
                
                // Calculate size for this major directory
                let (totalSize, totalCount) = Self.calculateDirectorySizeDeep(dirPath)
                
                let item = FolderItem(
                    name: url.lastPathComponent,
                    path: dirPath,
                    size: totalSize,
                    itemCount: totalCount,
                    lastModified: modDate,
                    isDirectory: true
                )
                items.append(item)
                
            } catch {
                // If we can't access it, skip it
                print("Cannot access \(dirPath): \(error)")
                continue
            }
        }
        
        return items.sorted()
    }
    
    private static func buildRootDirectoryItemsWithProgress(
        progressCallback: @escaping @MainActor @Sendable (Int, String) -> Void
    ) async -> [FolderItem] {
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
        
        var items: [FolderItem] = []
        let fileManager = FileManager.default
        
        for (index, dirPath) in rootDirectories.enumerated() {
            let url = URL(fileURLWithPath: dirPath)
            
            await MainActor.run {
                progressCallback(index + 1, url.lastPathComponent)
            }
            
            // Check if directory exists and is accessible
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: dirPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            
            do {
                let attributes = try fileManager.attributesOfItem(atPath: dirPath)
                let modDate = attributes[.modificationDate] as? Date ?? Date()
                
                // Calculate size for this major directory
                let (totalSize, totalCount) = Self.calculateDirectorySizeDeep(dirPath)
                
                let item = FolderItem(
                    name: url.lastPathComponent,
                    path: dirPath,
                    size: totalSize,
                    itemCount: totalCount,
                    lastModified: modDate,
                    isDirectory: true
                )
                items.append(item)
                
            } catch {
                // If we can't access it, skip it
                print("Cannot access \(dirPath): \(error)")
                continue
            }
        }
        
        return items.sorted()
    }
    
    private static func buildDirectoryTreeWithProgress(
        at rootURL: URL,
        progressCallback: @escaping @MainActor @Sendable (Int, String) -> Void
    ) async -> [FolderItem] {
        let fileManager = FileManager.default
        
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
            .nameKey
        ]
        
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
            
            var items: [FolderItem] = []
            var directoryItems: [FolderItem] = []
            var fileItems: [FolderItem] = []
            
            for (index, url) in contents.enumerated() {
                await MainActor.run {
                progressCallback(index + 1, url.lastPathComponent)
            }
                
                if let baseItem = Self.createBaseItem(from: url, keys: keys) {
                    if baseItem.isDirectory {
                        // Calculate actual size recursively for this directory
                        let (totalSize, totalCount) = Self.calculateDirectorySizeDeep(url.path)
                        
                        let directoryItem = FolderItem(
                            name: baseItem.name,
                            path: baseItem.path,
                            size: totalSize,
                            itemCount: totalCount,
                            lastModified: baseItem.lastModified,
                            isDirectory: true
                        )
                        directoryItems.append(directoryItem)
                    } else {
                        fileItems.append(baseItem)
                    }
                }
            }
            
            items = directoryItems + fileItems
            return items
            
        } catch {
            print("Error building directory tree with progress for \(rootURL.path): \(error)")
            return []
        }
    }
    
    private static func createBaseItem(from url: URL, keys: [URLResourceKey]) -> FolderItem? {
        do {
            let resourceValues = try url.resourceValues(forKeys: Set(keys))
            
            // Skip symbolic links to avoid cycles
            if resourceValues.isSymbolicLink == true {
                return nil
            }
            
            let name = resourceValues.name ?? url.lastPathComponent
            let isDirectory = resourceValues.isDirectory == true
            let modificationDate = resourceValues.contentModificationDate ?? Date()
            
            if isDirectory {
                // For directories, we'll calculate size separately - just create basic item
                return FolderItem(
                    name: name,
                    path: url.path,
                    size: 0, // Will be updated later
                    itemCount: 0, // Will be updated later
                    lastModified: modificationDate,
                    isDirectory: true
                )
            } else {
                // For files, use allocated size for more accurate disk usage
                let allocatedSize = resourceValues.totalFileAllocatedSize ?? resourceValues.fileSize ?? 0
                return FolderItem(
                    name: name,
                    path: url.path,
                    size: Int64(allocatedSize),
                    itemCount: 1,
                    lastModified: modificationDate,
                    isDirectory: false
                )
            }
        } catch {
            return nil
        }
    }
    
    
    private static func calculateDirectorySizeDeep(_ path: String) -> (size: Int64, count: Int) {
        let rootURL = URL(fileURLWithPath: path)
        let usage = directoryDiskUsage(at: rootURL)
        return (Int64(usage.totalAllocated), usage.fileCount)
    }
    
    private static func directoryDiskUsage(at rootURL: URL) -> DiskUsage {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileResourceIdentifierKey
        ]
        
        var usage = DiskUsage()
        var seenResourceIDs = Set<AnyHashable>() // de-dupe hard links
        
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                // Return true to continue on permission/IO errors
                return true
            }
        ) else { return usage }
        
        for case let url as URL in enumerator {
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                
                // Skip symlinks; they don't contribute storage and can create cycles
                if values.isSymbolicLink == true { continue }
                
                guard values.isRegularFile == true else { continue }
                
                // Avoid double-counting hard links by tracking stable per-file ID
                if let rid = values.fileResourceIdentifier {
                    // Create a string representation for hashing since the identifier type varies
                    let hashableRid = AnyHashable(String(describing: rid))
                    let (inserted, _) = seenResourceIDs.insert(hashableRid)
                    if !inserted { continue } // already seen this file content
                }
                
                let allocated = values.totalFileAllocatedSize ?? 0
                usage.fileCount &+= 1
                usage.totalAllocated &+= allocated
            } catch {
                // Ignore metadata failures on single files but keep walking
                continue
            }
        }
        
        return usage
    }
    
    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
        scanProgress = ""
    }
    
    // MARK: - High-Performance Bounded Parallel Scanning
    
    private static func boundedParallelScan(rootURL: URL) async -> [FolderItem] {
        // For full recursive scanning, we need to build the complete tree upfront
        // This ensures all folder sizes are calculated immediately
        
        // Check if we can access this directory
        guard FileManager.default.isReadableFile(atPath: rootURL.path) else {
            print("No read access to \(rootURL.path)")
            return []
        }
        
        // Special handling for root directory - use the existing optimized approach
        if rootURL.path == "/" {
            return await buildRootDirectoryItemsAsync()
        }
        
        // For other directories, do a complete recursive scan
        return await buildCompleteDirectoryTreeAsync(at: rootURL)
    }
    
    private static func processURL(_ url: URL, seenResourceIDs: NSMutableSet) async -> FolderItem? {
        do {
            // All metadata is prefetched in one go
            let resourceValues = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ])
            
            // Skip symlinks to prevent cycles
            if resourceValues.isSymbolicLink == true {
                return nil
            }
            
            // Skip if we've already seen this resource (hard link deduplication)
            if let resourceID = resourceValues.fileResourceIdentifier {
                if seenResourceIDs.contains(resourceID) {
                    return nil
                }
                seenResourceIDs.add(resourceID)
            }
            
            let isDirectory = resourceValues.isDirectory ?? false
            let size: Int64
            let itemCount: Int
            
            if isDirectory {
                let diskUsage = await directoryDiskUsageAsync(at: url)
                size = diskUsage.size
                itemCount = diskUsage.itemCount
            } else {
                size = Int64(resourceValues.totalFileAllocatedSize ?? 0)
                itemCount = 1
            }
            
            return FolderItem(
                name: url.lastPathComponent,
                path: url.path,
                size: size,
                itemCount: itemCount,
                lastModified: resourceValues.contentModificationDate ?? Date.distantPast,
                isDirectory: isDirectory
            )
            
        } catch {
            // Skip files we can't access
            print("Error accessing \(url.path): \(error)")
            return nil
        }
    }
    
    private static func directoryDiskUsageAsync(at rootURL: URL) async -> DiskUsage {
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
    
    private static func enumerateDirectoryRecursive(at rootURL: URL, seenResourceIDs: NSMutableSet) async -> DiskUsage {
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
    
    private static func buildRootDirectoryItemsAsync() async -> [FolderItem] {
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
        
        let maxConcurrency = min(ProcessInfo.processInfo.activeProcessorCount * 2, 16)
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
                
                // Calculate full directory size asynchronously
                group.addTask {
                    let diskUsage = await directoryDiskUsageAsync(at: url)
                    
                    return FolderItem(
                        name: url.lastPathComponent,
                        path: url.path,
                        size: diskUsage.size,
                        itemCount: diskUsage.itemCount,
                        lastModified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast,
                        isDirectory: true
                    )
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
    
    private static func buildCompleteDirectoryTreeAsync(at rootURL: URL) async -> [FolderItem] {
        let maxConcurrency = min(ProcessInfo.processInfo.activeProcessorCount * 2, 16)
        
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
            var activeTasks = 0
            
            return await withTaskGroup(of: FolderItem?.self) { group in
                for url in contents {
                    // Bound the parallelism
                    while activeTasks >= maxConcurrency {
                        if let item = await group.next() {
                            if let validItem = item {
                                items.append(validItem)
                            }
                            activeTasks -= 1
                        }
                    }
                    
                    // Process each item with full recursive calculation
                    group.addTask {
                        let seenResourceIDs = NSMutableSet()
                        return await processURLComplete(url, seenResourceIDs: seenResourceIDs)
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
            
        } catch {
            print("Error scanning directory \(rootURL.path): \(error)")
            return []
        }
    }
    
    private static func processURLComplete(_ url: URL, seenResourceIDs: NSMutableSet) async -> FolderItem? {
        do {
            // All metadata is prefetched in one go
            let resourceValues = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ])
            
            // Skip symlinks to prevent cycles
            if resourceValues.isSymbolicLink == true {
                return nil
            }
            
            // Skip if we've already seen this resource (hard link deduplication)
            if let resourceID = resourceValues.fileResourceIdentifier {
                if seenResourceIDs.contains(resourceID) {
                    return nil
                }
                seenResourceIDs.add(resourceID)
            }
            
            let isDirectory = resourceValues.isDirectory ?? false
            let size: Int64
            let itemCount: Int
            
            if isDirectory {
                // Always do full recursive calculation for directories
                let diskUsage = await directoryDiskUsageAsync(at: url)
                size = diskUsage.size
                itemCount = diskUsage.itemCount
            } else {
                size = Int64(resourceValues.totalFileAllocatedSize ?? 0)
                itemCount = 1
            }
            
            return FolderItem(
                name: url.lastPathComponent,
                path: url.path,
                size: size,
                itemCount: itemCount,
                lastModified: resourceValues.contentModificationDate ?? Date.distantPast,
                isDirectory: isDirectory
            )
            
        } catch {
            // Skip files we can't access
            print("Error accessing \(url.path): \(error)")
            return nil
        }
    }
}
