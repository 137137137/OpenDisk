import Foundation
import Observation

@MainActor
@Observable
final class DiskAnalyzer {
    private static let maxVisibleChildren = 100
    private static let minVisibleSize: Int64 = 1_024

    private(set) var rootItems: [FolderItem] = []
    private(set) var chartRoot: ChartItem?
    private(set) var isScanning = false
    private(set) var unreadableDirectories = 0
    private(set) var needsFullDiskAccess = false
    private(set) var totalDiskScannedBytes: Int64 = 0
    private(set) var itemsScanned = 0
    private(set) var scanPhase: ScanPhase = .scanning
    private(set) var scanStartDate: Date?
    private(set) var scanDuration: TimeInterval = 0
    private(set) var displayedTotalBytes: Int64 = 0
    private(set) var displayVersion = 0

    private(set) var searchResults: [FolderItem] = []
    private(set) var searchTotalMatches = 0
    private(set) var searchResultsVersion = 0
    private(set) var isSearchRunning = false
    private(set) var searchResultsArePartial = false

    private let scanner: any DiskScanning
    private var scanResult: ScanResult?
    private var resultIsPartial = false
    private var scanRootPath = ""
    private(set) var currentPath = ""
    private var scanTask: Task<ScanResult, Never>?
    private var generation = 0
    private var lastAppliedPartialSequence = 0
    private var searchIndex: SearchIndex?
    private var searchIndexIsPartial = false
    private var searchIndexBuildTask: Task<Void, Never>?
    private var searchQuery = ""
    private var searchScope: SearchScope = .all
    private var searchSequence = 0
    private var searchTask: Task<Void, Never>?

    init(scanner: any DiskScanning = ScanEngine()) {
        self.scanner = scanner
    }

    func scanDirectory(_ path: String) async {
        cancelCurrentScan()
        generation &+= 1
        let generation = self.generation

        if !ScanAccess.isSandboxed && path == "/" && !FullDiskAccess.isGranted {
            needsFullDiskAccess = true
            rootItems = []
            return
        }

        needsFullDiskAccess = false
        isScanning = true
        totalDiskScannedBytes = 0
        itemsScanned = 0
        scanPhase = .scanning
        scanDuration = 0
        scanRootPath = path
        currentPath = path
        scanResult = nil
        resultIsPartial = false
        lastAppliedPartialSequence = 0
        rootItems = []
        chartRoot = nil
        unreadableDirectories = 0
        displayedTotalBytes = 0
        displayVersion += 1
        searchIndexBuildTask?.cancel()
        searchIndexBuildTask = nil
        searchTask?.cancel()
        searchTask = nil
        searchIndex = nil
        searchIndexIsPartial = false
        searchSequence += 1
        searchResults = []
        searchTotalMatches = 0
        isSearchRunning = !searchQuery.isEmpty
        let startDate = Date()
        scanStartDate = startDate

        Task { [weak self] in
            let items = await Self.skeletonItems(forRoot: path)
            guard let self, self.generation == generation, self.isScanning,
                  self.scanResult == nil else { return }
            self.rootItems = items
            self.displayedTotalBytes = items.reduce(0) { $0 + $1.size }
            self.displayVersion += 1
        }

        let scanner = self.scanner
        let handleEvent: @Sendable (ScanEvent) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, generation: generation, startedAt: startDate)
            }
        }
        let task = Task {
            await scanner.scan(path: path, onEvent: handleEvent)
        }
        scanTask = task
        let result = await task.value
        guard scanTask == task else {
            if self.generation == generation {
                isScanning = false
                isSearchRunning = false
                scanStartDate = nil
            }
            return
        }
        scanTask = nil

        scanResult = result
        resultIsPartial = false
        refreshDisplayedItems()
        scanDuration = Date().timeIntervalSince(startDate)
        isScanning = false
        unreadableDirectories = result.unreadableDirectories
        totalDiskScannedBytes = result.tree.size(of: FileTree.rootID)
        itemsScanned = max(itemsScanned, result.tree.nodeCount - 1)
        rebuildSearchIndex()
    }

    func cancelCurrentScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    @discardableResult
    func navigateToPath(_ path: String) -> Bool {
        if path == HiddenSpaceInfo.sentinelPath {
            guard !cleanableCacheEntries().isEmpty else { return false }
            currentPath = path
            displayCleanableSpace()
            return true
        }
        guard let node = nodeID(forPath: path) else { return false }
        currentPath = path
        display(node: node)
        return true
    }

    private func displayCleanableSpace() {
        var items = cleanableCacheEntries().map {
            FolderItem(name: $0.name, path: $0.path, size: $0.size, isDirectory: true, itemCount: 0)
        }
        items.sort { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
        rootItems = items
        displayedTotalBytes = items.reduce(0) { $0 + $1.size }
        displayVersion += 1
        chartRoot = cleanableChartRoot(items: items, total: displayedTotalBytes)
    }

    private func cleanableChartRoot(items: [FolderItem], total: Int64) -> ChartItem? {
        guard total > 0 else { return nil }
        var children: [ChartItem] = []
        var cursor = 0.0
        for item in items {
            let share = Double(item.size) / Double(total) * 100
            children.append(ChartItem(
                name: item.name, path: item.path, size: item.size,
                depth: 1, relStart: cursor, relSize: share,
                fractionOfRoot: share / 100,
                kind: item.isDirectory ? .directory : .file,
                hasHiddenChildren: false, children: []
            ))
            cursor += share
        }
        return ChartItem(
            name: HiddenSpaceInfo.folderName,
            path: HiddenSpaceInfo.sentinelPath,
            size: total, depth: 0, relStart: 0, relSize: 100,
            fractionOfRoot: 1, kind: .synthetic,
            hasHiddenChildren: false, children: children
        )
    }

    private func cleanableCacheEntries() -> [(name: String, path: String, size: Int64)] {
        guard let result = scanResult else { return [] }
        return CleanableCacheCatalog.locations.compactMap { location in
            guard let node = result.tree.nodeID(forPath: location.path, rootPath: result.rootPath),
                  result.tree.isDirectory(node) else { return nil }
            let size = result.tree.size(of: node)
            guard size > 0 else { return nil }
            return (location.name, location.path, size)
        }
    }

    func collectablePurgeableFiles() -> [CollectedFile] {
        cleanableCacheEntries().map {
            CollectedFile(path: $0.path, name: $0.name, size: $0.size, isDirectory: true)
        }
    }

    private func handle(_ event: ScanEvent, generation: Int, startedAt: Date) {
        guard generation == self.generation, isScanning else { return }

        switch event {
        case .progress(let progress):
            apply(progress, startedAt: startedAt)

        case .partial(let partial):
            guard partial.sequence > lastAppliedPartialSequence else { return }
            lastAppliedPartialSequence = partial.sequence
            scanResult = ScanResult(rootPath: scanRootPath, tree: partial.tree)
            resultIsPartial = true
            refreshDisplayedItems()
            if !searchQuery.isEmpty && searchIndex == nil && searchIndexBuildTask == nil {
                rebuildSearchIndex()
            }
        }
    }

    private func apply(_ progress: ScanProgress, startedAt: Date) {
        totalDiskScannedBytes = progress.scannedBytes
        itemsScanned = progress.itemsScanned
        scanPhase = progress.phase
    }

    private func refreshDisplayedItems() {
        if let node = nodeID(forPath: currentPath) {
            display(node: node)
        } else if !resultIsPartial {
            currentPath = scanRootPath
            display(node: FileTree.rootID)
        }
    }

    private func display(node: FileTree.NodeID) {
        rootItems = folderItems(for: node, limit: displayLimit(for: currentPath))
        if currentPath == scanRootPath {
            let caches = cleanableCacheEntries()
            let cacheTotal = caches.reduce(0) { $0 + $1.size }
            if cacheTotal > 0 {
                let row = FolderItem(
                    name: HiddenSpaceInfo.folderName,
                    path: HiddenSpaceInfo.sentinelPath,
                    size: cacheTotal,
                    isDirectory: true,
                    itemCount: caches.count
                )
                rootItems.insert(row, at: 0)
            }
        }
        displayedTotalBytes = scanResult?.tree.size(of: node) ?? 0
        displayVersion += 1
        scheduleChartRebuild(for: node)
    }

    private var pendingChartNode: FileTree.NodeID?
    private var chartRebuildScheduled = false

    private func scheduleChartRebuild(for node: FileTree.NodeID) {
        pendingChartNode = node
        guard !chartRebuildScheduled else { return }
        chartRebuildScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.chartRebuildScheduled = false
            guard let node = self.pendingChartNode else { return }
            self.pendingChartNode = nil
            self.rebuildChartRoot(for: node)
        }
    }

    private func rebuildChartRoot(for node: FileTree.NodeID) {
        guard let tree = scanResult?.tree, tree.isDirectory(node) else {
            chartRoot = nil
            return
        }
        let name = (currentPath as NSString).lastPathComponent
        chartRoot = ChartItem.build(
            from: tree, at: node, name: name, path: currentPath
        )
    }

    func updateSearch(query: String, scope: SearchScope) {
        searchQuery = query.trimmingCharacters(in: .whitespaces)
        searchScope = scope
        runActiveSearch()
    }

    private func runActiveSearch() {
        searchSequence += 1
        let sequence = searchSequence
        searchTask?.cancel()
        searchTask = nil

        guard !searchQuery.isEmpty else {
            searchResults = []
            searchTotalMatches = 0
            searchResultsVersion += 1
            isSearchRunning = false
            return
        }
        guard let index = searchIndex else {
            isSearchRunning = true
            if searchIndexBuildTask == nil { rebuildSearchIndex() }
            return
        }

        isSearchRunning = true
        let query = searchQuery
        let scope = searchScope
        let fromPartial = searchIndexIsPartial
        searchTask = Task { [weak self] in
            let results = await index.search(query: query, scope: scope)
            guard let self, !Task.isCancelled, self.searchSequence == sequence else { return }
            self.searchResults = results.items
            self.searchTotalMatches = results.totalMatches
            self.searchResultsVersion += 1
            self.searchResultsArePartial = fromPartial
            self.isSearchRunning = false
        }
    }

    private func rebuildSearchIndex() {
        searchIndexBuildTask?.cancel()
        guard let result = scanResult else {
            searchIndexBuildTask = nil
            return
        }
        let tree = result.tree
        let isPartial = resultIsPartial
        let generation = generation
        searchIndexBuildTask = Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) {
                SearchIndex(tree: tree)
            }.value
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.searchIndex = index
            self.searchIndexIsPartial = isPartial
            self.searchIndexBuildTask = nil
            self.runActiveSearch()
        }
    }

    private func displayLimit(for path: String) -> Int? {
        path == scanRootPath ? nil : Self.maxVisibleChildren
    }

    private func nodeID(forPath path: String) -> FileTree.NodeID? {
        guard let result = scanResult else { return nil }
        return result.tree.nodeID(forPath: path, rootPath: result.rootPath)
    }

    private func folderItems(for node: FileTree.NodeID, limit: Int?) -> [FolderItem] {
        guard let tree = scanResult?.tree, tree.isDirectory(node) else { return [] }
        let minVisibleSize = resultIsPartial ? Int64(-1) : Self.minVisibleSize
        return tree.childrenSortedForDisplay(of: node)
            .prefix(limit ?? Int.max)
            .filter { tree.size(of: $0) > minVisibleSize }
            .map { child in
                FolderItem(
                    name: tree.name(of: child),
                    path: tree.path(of: child),
                    size: tree.size(of: child),
                    isDirectory: tree.isDirectory(child),
                    itemCount: tree.childCount(of: child)
                )
            }
    }

    private nonisolated static func skeletonItems(forRoot path: String) async -> [FolderItem] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: readSkeleton(path))
            }
        }
    }

    private nonisolated static func readSkeleton(_ path: String) -> [FolderItem] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .totalFileAllocatedSizeKey,
            .isSymbolicLinkKey, .isHiddenKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: Array(keys)
        ) else {
            return []
        }

        let prefix = path.directoryPrefix
        var directories: [FolderItem] = []
        var files: [FolderItem] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true || values?.isHidden == true { continue }
            let isDirectory = values?.isDirectory ?? false
            let name = url.lastPathComponent
            let item = FolderItem(
                name: name,
                path: prefix + name,
                size: isDirectory ? 0 : Int64(values?.totalFileAllocatedSize ?? 0),
                isDirectory: isDirectory,
                itemCount: 0,
                sizeIsKnown: !isDirectory
            )
            if isDirectory {
                directories.append(item)
            } else {
                files.append(item)
            }
        }
        directories.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        files.sort { $0.size > $1.size }
        return directories + files
    }
}
