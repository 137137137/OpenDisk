import Foundation
import Darwin
import Observation

/// Simplified disk analyzer that delegates to specialized services.
///
/// Uses Swift's `@Observable` macro (macOS 14+) for efficient UI updates.
/// Supports dependency injection for testability:
/// ```swift
/// // Production use (default):
/// let analyzer = DiskAnalyzer()
///
/// // Testing with mocks:
/// let analyzer = DiskAnalyzer(scanner: MockScanner(), cache: MockCache())
/// ```
@MainActor
@Observable
final class DiskAnalyzer {
    // MARK: - Observable Properties (UI State)
    var rootItems: [FolderItem] = []
    var totalSize: Int64 = 0
    var totalDiskScannedBytes: Int64 = 0
    var scanDuration: TimeInterval = 0

    // Keep the complete tree structure for instant navigation
    private var completeTree: [FolderItem] = []
    // V24: Store raw scan data for on-demand conversion
    private var rawScanData: HyperScanItem?

    // MARK: - Observable Properties for Progress
    var isScanning: Bool = false
    var scanProgress: String = ""
    var scanProgressPercentage: Double = 0.0
    var currentScanPath: String = ""
    var estimatedTimeRemaining: String = ""
    var filesPerSecond: String = ""

    // MARK: - Services (Injected via Protocols)
    private let cache: any CacheProtocol
    private let scanner: any ScannerProtocol

    // MARK: - Initialization

    /// Creates a DiskAnalyzer with optional dependency injection.
    ///
    /// - Parameters:
    ///   - scanner: Scanner implementation (defaults to HyperScanner)
    ///   - cache: Cache implementation (defaults to CacheManager)
    init(scanner: any ScannerProtocol = HyperScanner(), cache: any CacheProtocol = CacheManager()) {
        self.scanner = scanner
        self.cache = cache
    }

    // MARK: - State
    private var currentPath: String = ""
    private var initialScanPath: String = ""
    private var scanTask: Task<Void, Never>?
    private var scanStartTime: Date?

    // MARK: - Public Methods

    /// Scan a directory (compatibility method)
    func scanDirectory(_ path: String) async {
        // Cancel any existing scan
        cancelCurrentScan()

        // Store the initial scan path
        initialScanPath = path

        // Start scan
        isScanning = true
        scanProgress = "Preparing high-performance scan..."
        scanProgressPercentage = 0.0
        estimatedTimeRemaining = ""
        filesPerSecond = ""
        currentScanPath = ""
        scanStartTime = Date()
        scanDuration = 0

        // Check Full Disk Access
        if path == "/" && !hasFullDiskAccess() {
            scanProgress = "Full Disk Access required. Grant in System Settings > Privacy & Security."
            scanProgressPercentage = 0
            isScanning = false
            return
        }

        // Perform scan
        let hyperResult = await performHyperScan(path: path)

        // V24: Store raw data for on-demand conversion
        rawScanData = hyperResult

        // Fast conversion - only convert visible items immediately
        // Use the optimized toFolderItem() that only processes top 100 items
        var items = hyperResult.children?.map { $0.toFolderItem() } ?? []

        // Quick filter and sort of just root level
        items = items.filter { $0.size > 1024 }.sorted { $0.size > $1.size }
        ScanResultProcessor.calculatePercentages(for: &items)

        // Display immediately (no freeze!)
        updateUI(with: items, path: path)

        // Store for navigation (lightweight now with only top 100 items per folder)
        completeTree = items

        // Optional: Background conversion of full tree (low priority)
        Task.detached(priority: .utility) {
            // Convert more data in background for smoother navigation
            // This happens after UI is already responsive
            if let fullItems = hyperResult.children {
                for item in fullItems where item.children?.count ?? 0 > 100 {
                    // Pre-convert folders with many items
                    _ = item.toFolderItem()
                }
            }
        }

        // Complete scan
        isScanning = false
        scanProgressPercentage = 100.0

        // Calculate scan duration
        if let startTime = scanStartTime {
            scanDuration = Date().timeIntervalSince(startTime)
        }
    }

    /// Navigate to a path, using cache if available (synchronous for UI)
    func navigateToPath(_ path: String) -> Bool {
        // If already showing this path, return immediately
        if path == currentPath && !rootItems.isEmpty {
            return true
        }

        // Look for the path in the current tree structure - should be instant
        if let targetItems = findChildrenInTree(for: path) {
            updateUI(with: targetItems, path: path)
            return true
        }

        // Fallback to cache if not found in tree
        Task { @MainActor in
            if let cachedItems = await cache.get(for: path), !cachedItems.isEmpty {
                updateUI(with: cachedItems, path: path)
            }
        }

        return true // Always return true for UI compatibility
    }

    /// Find children for a path in the current tree structure
    private func findChildrenInTree(for targetPath: String) -> [FolderItem]? {
        // Special case: navigating to the initial scan root
        if targetPath == initialScanPath && !completeTree.isEmpty {
            return completeTree
        }

        func searchItems(_ items: [FolderItem]) -> [FolderItem]? {
            for item in items {
                if item.path == targetPath && item.isDirectory {
                    // V24: If children are empty (lazy loading), need to scan that path
                    if item.children.isEmpty && item.itemCount > 0 {
                        // Trigger background scan for this specific folder
                        Task {
                            await self.scanDirectory(targetPath)
                        }
                        return nil // Will be loaded async
                    }
                    return item.children
                }
                // Don't recurse into empty children (they're lazy-loaded)
                if item.isDirectory && !item.children.isEmpty {
                    if let found = searchItems(item.children) {
                        return found
                    }
                }
            }
            return nil
        }

        // Search in the complete tree (has everything from initial scan)
        return searchItems(completeTree)
    }



    /// Cancel current scan
    func cancelCurrentScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    /// Clear all caches
    func clearAllCaches() {
        Task {
            await cache.clearAll()
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

        return await scanner.scan(
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
        // V24: Only cache top-level items, not the entire tree
        // This prevents memory bloat and speeds up caching
        await cache.set(items, for: path)

        // Don't recursively cache - items are lazy-loaded now
        // Deep caching happens on-demand when user navigates
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
