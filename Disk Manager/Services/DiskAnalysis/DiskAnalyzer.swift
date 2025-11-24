import Foundation
import Darwin

/// Simplified disk analyzer that delegates to specialized services
@MainActor
final class DiskAnalyzer: ObservableObject {
    // MARK: - Published Properties (UI State)
    @Published var rootItems: [FolderItem] = []
    @Published var totalSize: Int64 = 0
    @Published var totalDiskScannedBytes: Int64 = 0

    // MARK: - Published Properties for Progress (for UI compatibility)
    @Published var isScanning: Bool = false
    @Published var scanProgress: String = ""
    @Published var scanProgressPercentage: Double = 0.0
    @Published var currentScanPath: String = ""
    @Published var estimatedTimeRemaining: String = ""
    @Published var filesPerSecond: String = ""

    // MARK: - Services (Single Responsibility)
    private let cacheManager = CacheManager()
    private let hyperScanner = HyperScanner()

    // MARK: - State
    private var currentPath: String = ""
    private var scanTask: Task<Void, Never>?

    // MARK: - Public Methods

    /// Scan a directory (compatibility method)
    func scanDirectory(_ path: String) async {
        scanDisk(path: path)
    }

    /// Navigate to a path, using cache if available (synchronous for UI)
    func navigateToPath(_ path: String) -> Bool {
        // If already showing this path, return immediately
        if path == currentPath && !rootItems.isEmpty {
            return true
        }

        // Start async navigation in background
        Task { @MainActor in
            await navigateToPathAsync(path)
        }

        return true // Always return true for UI compatibility
    }

    /// Navigate to a path asynchronously
    private func navigateToPathAsync(_ path: String) async -> Bool {
        // Check if already showing this path
        if path == currentPath && !rootItems.isEmpty {
            return true
        }

        // Try cache first
        if let cachedItems = await cacheManager.getCachedChildren(for: path), !cachedItems.isEmpty {
            updateUI(with: cachedItems, path: path)
            return true
        }

        // Need fresh scan - do a shallow scan for navigation
        let hyperResult = await performHyperScan(path: path)
        var items = ScanResultProcessor.convertToFolderItems(hyperResult)
        items = ScanResultProcessor.filterAndSort(items)

        if !items.isEmpty {
            await cacheResults(items, for: path)
            updateUI(with: items, path: path)
            return true
        }

        return false
    }

    /// Perform a full disk scan
    func scanDisk(path: String = "/") {
        cancelCurrentScan()

        scanTask = Task {
            // Start scan
            isScanning = true
            scanProgress = "Preparing high-performance scan..."
            scanProgressPercentage = 0.0
            estimatedTimeRemaining = ""
            filesPerSecond = ""
            currentScanPath = ""

            // Check Full Disk Access
            if path == "/" && !hasFullDiskAccess() {
                scanProgress = "Full Disk Access required. Grant in System Settings > Privacy & Security."
                scanProgressPercentage = 0
                isScanning = false
                return
            }

            // Perform scan
            let hyperResult = await performHyperScan(path: path)

            // Process results
            var items = ScanResultProcessor.convertToFolderItems(hyperResult)
            items = ScanResultProcessor.filterAndSort(items)
            ScanResultProcessor.calculatePercentages(for: &items)

            // Cache and display
            await cacheResults(items, for: path)
            updateUI(with: items, path: path)

            // Complete scan
            isScanning = false
            scanProgressPercentage = 100.0
        }
    }

    /// Cancel current scan
    func cancelCurrentScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    /// Clear all caches
    func clearAllCaches() {
        Task {
            await cacheManager.clearAll()
        }
    }

    /// Scan external volumes
    func scanExternalVolumes() async -> [FolderItem] {
        await Task.detached {
            var volumes: [FolderItem] = []
            let volumesPath = "/Volumes"

            guard let volumeList = try? FileManager.default.contentsOfDirectory(atPath: volumesPath) else {
                return []
            }

            for volumeName in volumeList {
                let volumePath = "\(volumesPath)/\(volumeName)"

                if PathFilter.shouldSkipVolume(volumeName) { continue }
                guard FileManager.default.isReadableFile(atPath: volumePath) else { continue }

                let volumeURL = URL(fileURLWithPath: volumePath)
                let size: Int64

                if let resourceValues = try? volumeURL.resourceValues(forKeys: [.volumeTotalCapacityKey]),
                   let capacity = resourceValues.volumeTotalCapacity {
                    size = Int64(capacity)
                } else {
                    size = 0
                }

                volumes.append(FolderItem(
                    name: volumeName,
                    path: volumePath,
                    size: size,
                    isDirectory: true,
                    itemCount: 1,
                    lastModified: Date()
                ))
            }

            return volumes.sorted()
        }.value
    }

    // MARK: - Private Methods

    private func performHyperScan(path: String) async -> HyperScanItem {
        let startTime = Date()

        return await hyperScanner.scan(
            url: URL(fileURLWithPath: path)
        ) { [weak self] progress in
            Task { @MainActor in
                guard let self = self else { return }

                self.scanProgress = "Scanning: \(ByteFormatter.formatFileSize(progress.scannedBytes)) (\(progress.itemsScanned.formatted()) items)"
                self.scanProgressPercentage = progress.fractionCompleted * 100.0
                self.currentScanPath = progress.currentPath
                self.totalDiskScannedBytes = progress.scannedBytes

                // Update files per second
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > 0 {
                    let rate = Double(progress.itemsScanned) / elapsed
                    self.filesPerSecond = "\(Int(rate)) files/sec"
                }

                // Update time remaining
                if progress.fractionCompleted > 0.05 {
                    let totalEstimated = elapsed / progress.fractionCompleted
                    let remaining = totalEstimated - elapsed
                    self.estimatedTimeRemaining = self.formatTimeInterval(remaining)
                } else {
                    self.estimatedTimeRemaining = "Calculating..."
                }
            }
        }
    }

    private func updateUI(with items: [FolderItem], path: String) {
        rootItems = items
        currentPath = path
        totalSize = items.reduce(0) { $0 + $1.size }

        var mutableItems = items
        ScanResultProcessor.calculatePercentages(for: &mutableItems)
        rootItems = mutableItems
    }

    private func cacheResults(_ items: [FolderItem], for path: String) async {
        await cacheManager.cacheChildren(items, for: path)

        // Also cache all subdirectory children for navigation
        func cacheRecursively(_ items: [FolderItem]) async {
            for item in items where item.isDirectory && !item.children.isEmpty {
                await cacheManager.cacheChildren(item.children, for: item.path)
                await cacheRecursively(item.children)
            }
        }

        await cacheRecursively(items)
    }

    private func hasFullDiskAccess() -> Bool {
        FileManager.default.isReadableFile(atPath: "/Library/Application Support")
    }

    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        if interval < 60 {
            return String(format: "%.0f seconds", interval)
        } else if interval < 3600 {
            return String(format: "%.1f minutes", interval / 60)
        } else {
            return String(format: "%.1f hours", interval / 3600)
        }
    }

    // MARK: - Static Helper

    static func getDirectoryTotalSizeFast(path: String) async -> Int64 {
        await Task.detached {
            var totalSize: Int64 = 0

            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                options: [.skipsPackageDescendants]
            ) else {
                return 0
            }

            while let url = enumerator.nextObject() as? URL {
                if let resourceValues = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                   let size = resourceValues.totalFileAllocatedSize {
                    totalSize += Int64(size)
                }
            }

            return totalSize
        }.value
    }
}
