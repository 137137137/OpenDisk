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

    // Whole-disk progress model
    @Published var totalDiskBytes: Int64 = 0
    @Published var totalDiskScannedBytes: Int64 = 0

    // Real-time cumulative progress tracking (actor for thread safety)
    private let cumulativeCounter = CumulativeCounter()

    private var scanTask: Task<Void, Never>?
    private var scanStartTime: Date?
    
    // HYPER: Ultra-fast scanner using getattrlistbulk
    private let hyperScanner = HyperScanner()
    private let fileSystemMonitor = FileSystemMonitor()

    // Complete folder tree for instant navigation
    private var folderTree: [String: [FolderItem]] = [:]

    // Pre-calculated directory sizes for instant progress bars
    private var sizeCache: [String: Int64] = [:]

    
    
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
        scanStartTime = Date()
        currentScanPath = ""
        filesPerSecond = ""
        totalDiskScannedBytes = 0
        await cumulativeCounter.reset()

        // Get total USED disk space for accurate progress tracking
        // This matches the sidebar display and what we're actually scanning
        if path == "/" {
            totalDiskBytes = getTotalDiskSize(path: path) // Gets USED bytes, not total capacity
        } else {
            // For subdirectory scans, we could get the directory's total size
            // but for now we'll rely on estimates
            totalDiskBytes = 0
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

                    let sizeStr = ByteFormatter.formatFileSize(progress.scannedBytes)
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

                // IMPORTANT: Cache ALL nested folder contents from HyperScanner
                // This prevents re-scanning when navigating into folders
                self.cacheNestedFolderTree(children: items)

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
                self?.scanProgress = "Analyzing \(folderName)"
                self?.currentScanPath = path
                self?.scanProgressPercentage = 0.0
            }
        } else {
            // Need to calculate size first
            await MainActor.run { [weak self, folderName, path] in
                self?.scanProgress = "Getting size of \(folderName)..."
                self?.currentScanPath = path
                self?.scanProgressPercentage = 0.0
            }
            
            totalDirectorySize = await DiskAnalyzer.getDirectoryTotalSizeFast(path: path)
            sizeCache[path] = totalDirectorySize
            
            await MainActor.run { [weak self, folderName] in
                self?.scanProgress = "Analyzing \(folderName)"
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

                            await MainActor.run {
                                // Update progress
                                self.scanProgressPercentage = capturedPercent

                                // Update real-time cumulative progress
                                self.totalDiskScannedBytes = capturedCumulative
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
                self.scanProgressPercentage = 100.0

                // Update final cumulative progress
                self.totalDiskScannedBytes = finalCumulative
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
    
    // MARK: - External Volumes
    
    func scanExternalVolumes() async -> [FolderItem] {
        let volumes = await Task.detached {
            var externalVolumes: [FolderItem] = []
            
            // Scan /Volumes for external drives and networks
            let volumesPath = "/Volumes"
            do {
                let volumeList = try FileManager.default.contentsOfDirectory(atPath: volumesPath)
                
                for volumeName in volumeList {
                    let volumePath = volumesPath + "/" + volumeName

                    // Skip system volumes and hidden volumes
                    if PathFilter.shouldSkipVolume(volumeName) {
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

        return volumes
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
            print("[DiskAnalyzer] Total disk used: \(ByteFormatter.formatFileSize(usedBytes))")
            return usedBytes
        }

        // Fallback: try to get volume capacity
        do {
            let resourceValues = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            let total = Int64(resourceValues.volumeTotalCapacity ?? 0)
            let available = Int64(resourceValues.volumeAvailableCapacity ?? 0)
            let used = total - available
            print("[DiskAnalyzer] Total disk used (fallback): \(ByteFormatter.formatFileSize(used))")
            return used
        } catch {
            print("[DiskAnalyzer] Error getting disk size: \(error)")
            return 0
        }
    }
    
    func clearAllCaches() {
        folderTree.removeAll()
        sizeCache.removeAll()
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

