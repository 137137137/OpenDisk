import Foundation
import Observation

/// Main-actor view model for the analysis screen: runs scans through an
/// injected `DiskScanning` implementation and serves navigable slices of
/// the resulting `FileTree` to the UI.
///
/// Results appear in three waves, each replacing the last:
/// 1. A skeleton — one directory read of the scan root, shown within
///    milliseconds with pending sizes.
/// 2. Live partial trees streamed by the scanner, with sizes growing as
///    the scan discovers more.
/// 3. The final tree.
@MainActor
@Observable
final class DiskAnalyzer {

    /// Only the largest entries of a directory are materialized for
    /// display; navigation into any of them is still exact.
    private static let maxVisibleChildren = 100
    /// Entries at or below this size are noise for a disk-usage view.
    /// Applied only to final results — during a live scan a directory's
    /// size starts at zero and grows, so nothing is hidden yet.
    private static let minVisibleSize: Int64 = 1_024

    // MARK: - Observable UI state

    private(set) var rootItems: [FolderItem] = []
    /// Depth-limited tree of the viewed directory for the chart views,
    /// rebuilt from the same (partial or final) snapshot as `rootItems`.
    /// Nil until the first snapshot arrives (charts show a placeholder
    /// during the skeleton phase — a shallow listing has no hierarchy).
    private(set) var chartRoot: ChartItem?
    /// The gap between the volume's used space and what the scan saw,
    /// measured after a completed volume-root scan. Shown (in the list
    /// and as a gray chart slice) only at the scan root.
    private(set) var hiddenSpace: HiddenSpaceInfo?
    private(set) var isScanning = false
    /// True when a scan of "/" was refused because Full Disk Access is
    /// missing.
    private(set) var needsFullDiskAccess = false
    private(set) var totalDiskScannedBytes: Int64 = 0
    private(set) var itemsScanned = 0
    /// When the running scan started; views derive throughput from it.
    private(set) var scanStartDate: Date?
    private(set) var scanDuration: TimeInterval = 0
    /// Total for the status bar: the viewed directory's actual size (plus
    /// hidden space at the scan root), not a sum of trimmed visible rows.
    private(set) var displayedTotalBytes: Int64 = 0
    /// Bumped whenever the displayed rows are replaced — a cheap value
    /// for views to animate on instead of diffing whole row arrays.
    private(set) var displayVersion = 0

    // MARK: - Search state

    /// The largest matches for the active query, size-descending, capped
    /// at `SearchIndex.resultLimit`.
    private(set) var searchResults: [FolderItem] = []
    /// Total matches before the display cap.
    private(set) var searchTotalMatches = 0
    /// True while an index build or query for the active search is in
    /// flight (the UI shows a spinner instead of "no results").
    private(set) var isSearchRunning = false
    /// True when the shown results were computed from a mid-scan partial
    /// snapshot rather than a finished tree.
    private(set) var searchResultsArePartial = false

    // MARK: - Dependencies & state

    private let scanner: any DiskScanning
    private var scanResult: ScanResult?
    /// True while `scanResult` holds a live partial snapshot rather than a
    /// finished scan.
    private var resultIsPartial = false
    /// The path the running (or last finished) scan is rooted at.
    private var scanRootPath = ""
    /// The directory whose contents are on screen; may be deeper than the
    /// scan root while the user navigates.
    private var currentPath = ""
    private var scanTask: Task<ScanResult, Never>?
    /// Bumped per scan. Scan events hop to the main actor asynchronously,
    /// so every event carries the generation it belongs to and stale ones
    /// are dropped.
    private var generation = 0
    /// Partial snapshots can arrive out of order; only ever apply forward.
    private var lastAppliedPartialSequence = 0
    /// Search index over the current `scanResult` tree, or nil until one
    /// is built. Built eagerly when a scan finishes and on demand when the
    /// user searches mid-scan.
    private var searchIndex: SearchIndex?
    /// True when `searchIndex` was built from a partial snapshot.
    private var searchIndexIsPartial = false
    private var searchIndexBuildTask: Task<Void, Never>?
    /// The active query/scope as last set by the UI; kept so results can
    /// re-run when a fresh index lands.
    private var searchQuery = ""
    private var searchScope: SearchScope = .all
    /// Bumped per search request; async completions drop stale results.
    private var searchSequence = 0
    /// The in-flight query task; cancelled the moment a newer keystroke
    /// supersedes it so stacked searches never pile up on the cores.
    private var searchTask: Task<Void, Never>?

    init(scanner: any DiskScanning = ScanEngine()) {
        self.scanner = scanner
    }

    // MARK: - Scanning

    /// Scans `path` and shows its contents, streaming results as they are
    /// discovered.
    func scanDirectory(_ path: String) async {
        cancelCurrentScan()
        generation &+= 1
        let generation = self.generation

        if path == "/" && !FullDiskAccess.isGranted {
            needsFullDiskAccess = true
            rootItems = []
            return
        }

        needsFullDiskAccess = false
        isScanning = true
        totalDiskScannedBytes = 0
        itemsScanned = 0
        scanDuration = 0
        scanRootPath = path
        currentPath = path
        scanResult = nil
        resultIsPartial = false
        lastAppliedPartialSequence = 0
        rootItems = []
        chartRoot = nil
        hiddenSpace = nil
        displayedTotalBytes = 0
        displayVersion += 1
        // The old tree's index is stale the moment a rescan starts. An
        // active query stays active and resolves against the new tree
        // (mid-scan on demand, and again when the scan finishes).
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

        // Instant skeleton: one shallow directory read shows the top-level
        // names right away, before the scan has produced any numbers.
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
        // Task equality is identity-based: bail if another scan superseded
        // this one while it was awaited.
        guard scanTask == task else { return }
        scanTask = nil

        scanResult = result
        resultIsPartial = false
        refreshDisplayedItems()
        scanDuration = Date().timeIntervalSince(startDate)
        isScanning = false
        probeHiddenSpace(for: result, generation: generation)
        // Always index the finished tree (a few hundred ms, off-main) so
        // the first keystroke of a later search is instant; if a search is
        // already active it re-resolves against the final tree.
        rebuildSearchIndex()
    }

    /// Whether the currently viewed directory should show the hidden-space
    /// entry (only the scan root of a volume accounts for whole-volume
    /// used space).
    var hiddenSpaceForCurrentDirectory: HiddenSpaceInfo? {
        currentPath == scanRootPath ? hiddenSpace : nil
    }

    /// Measures purgeable space, snapshots and the unscanned remainder
    /// once a volume-root scan finishes.
    private func probeHiddenSpace(for result: ScanResult, generation: Int) {
        let path = result.rootPath
        let scanned = result.tree.size(of: FileTree.rootID)
        Task { [weak self] in
            let info = await Task.detached(priority: .utility) { () -> HiddenSpaceInfo? in
                guard path == "/" || VolumeAttributes.isVolumeRoot(path) else { return nil }
                return HiddenSpaceProbe.probe(volumePath: path, scannedBytes: scanned)
            }.value
            guard let self, self.generation == generation, let info else { return }
            self.hiddenSpace = info
            self.refreshDisplayedItems()
        }
    }

    /// Cancels a scan in flight, if any.
    func cancelCurrentScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Navigation

    /// Shows the contents of `path`, resolved instantly from the scanned
    /// tree (partial or complete).
    ///
    /// Returns false when the path is not in the tree — either outside the
    /// scan entirely, or simply not discovered yet by a running scan;
    /// callers decide whether that warrants a fresh scan.
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

    /// Contents of the synthetic "Purgeable Space" folder: the curated cache
    /// locations resolved against the scanned tree. Each is a real, deletable
    /// folder (navigable onward); their bytes also live under their true
    /// parents, so this is a curated cleanup lens, not a disjoint partition of
    /// the disk. (macOS's auto-managed purgeable pool has no deletable path —
    /// the OS frees it on demand — so it isn't listed here.)
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

    /// One-ring chart of the cleanable view: cache slices are real
    /// directories (clickable), the purgeable pool is a plain slice.
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

    /// Catalog locations that exist in the scanned tree with nonzero size.
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

    /// The cleanable cache folders as Collector payloads. Dragging the
    /// "Purgeable Space" row expands to exactly these, so the collected total
    /// matches the row's size and deleting them frees that space.
    func collectablePurgeableFiles() -> [CollectedFile] {
        cleanableCacheEntries().map {
            CollectedFile(path: $0.path, name: $0.name, size: $0.size, isDirectory: true)
        }
    }

    // MARK: - Event handling

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
            // A search typed before the first snapshot arrived had no tree
            // to index; index this one. Later snapshots don't re-index (a
            // multi-million-node rebuild per 500 ms snapshot would starve
            // cores) — mid-scan results refine when the scan finishes.
            if !searchQuery.isEmpty && searchIndex == nil && searchIndexBuildTask == nil {
                rebuildSearchIndex()
            }
        }
    }

    private func apply(_ progress: ScanProgress, startedAt: Date) {
        totalDiskScannedBytes = progress.scannedBytes
        itemsScanned = progress.itemsScanned
    }

    /// Re-materializes the on-screen rows from the current tree, keeping
    /// the user's position. While a partial tree does not contain the
    /// viewed directory yet, whatever is on screen (skeleton or an older
    /// snapshot) stays put rather than flashing empty.
    private func refreshDisplayedItems() {
        if let node = nodeID(forPath: currentPath) {
            display(node: node)
        } else if !resultIsPartial {
            currentPath = scanRootPath
            display(node: FileTree.rootID)
        }
    }

    /// Replaces the on-screen rows, chart and totals with `node`'s
    /// contents — the one place display state is derived from the tree.
    private func display(node: FileTree.NodeID) {
        rootItems = folderItems(for: node, limit: displayLimit(for: currentPath))
        // At the scan root, pin a "Purgeable Space" shortcut that aggregates
        // the cleanable caches. It's a cleanup lens — its bytes also live
        // under their real parents, so it is NOT added to the disk total —
        // sized to the cache total so it matches what dragging it collects
        // and what deleting it frees.
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
        // Defer the sunburst rebuild off the navigation's critical path so the
        // list (what you're clicking through) transitions instantly. The
        // chart's recursive depth-5 build can be heavy for large folders;
        // running it a tick later keeps clicks responsive. Rapid navigations
        // coalesce to the latest node.
        scheduleChartRebuild(for: node)
    }

    /// Deferred, coalesced chart rebuild — see `display(node:)`.
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
        // The center ring shows the volume/folder's display name — its last
        // path component — e.g. "2TB External", not "/Volumes/2TB External".
        // ("/" stays "/".)
        let name = (currentPath as NSString).lastPathComponent
        // The chart shows the true hierarchy; the "Purgeable Space" cleanup
        // lens is a list-only shortcut (its bytes already appear under their
        // real parents in the chart), so no synthetic slice is added.
        chartRoot = ChartItem.build(
            from: tree, at: node, name: name, path: currentPath,
            extraSlice: nil
        )
    }

    // MARK: - Search

    /// Sets the active query/scope and (re)runs the search. Searches are
    /// fast enough (~ms over millions of names) to run on every keystroke
    /// with no debounce; a sequence counter drops out-of-order completions.
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
            isSearchRunning = false
            return
        }
        guard let index = searchIndex else {
            // No index yet: mid-scan before any snapshot, or a build is
            // already in flight. Either way the pending build re-runs the
            // active search when it lands.
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
            self.searchResultsArePartial = fromPartial
            self.isSearchRunning = false
        }
    }

    /// Builds a fresh index from the current tree off the main actor, then
    /// re-runs the active search against it.
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

    // MARK: - Private helpers

    /// The scan root shows everything (matching the previous engine);
    /// drill-in levels pass a limit so a 100k-entry folder never
    /// materializes 100k path strings.
    private func displayLimit(for path: String) -> Int? {
        path == scanRootPath ? nil : Self.maxVisibleChildren
    }

    private func nodeID(forPath path: String) -> FileTree.NodeID? {
        guard let result = scanResult else { return nil }
        return result.tree.nodeID(forPath: path, rootPath: result.rootPath)
    }

    private func folderItems(for node: FileTree.NodeID, limit: Int?) -> [FolderItem] {
        guard let tree = scanResult?.tree, tree.isDirectory(node) else { return [] }
        // Live results keep zero-size entries (their sizes are still
        // arriving); finished results hide sub-1KB noise.
        let minVisibleSize = resultIsPartial ? Int64(-1) : Self.minVisibleSize
        // Sort and trim on node IDs first so only the visible rows ever
        // materialize path strings.
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

    // MARK: - Skeleton

    /// One shallow, non-recursive directory read of the scan root,
    /// performed off the main thread (a cold or network directory can make
    /// even a single `readdir` slow).
    private nonisolated static func skeletonItems(forRoot path: String) async -> [FolderItem] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: readSkeleton(path))
            }
        }
    }

    /// Directories come first, alphabetically, with pending sizes; files
    /// follow with their real allocated sizes.
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
            // Skeleton rows that can't survive the scan cause a jarring flash:
            // they show for a moment, then vanish once real results land.
            //   • Symlinks (/home, /etc, /var, /.file, …) are never followed by
            //     the scanner, so they never appear in the tree. (Firmlinked
            //     dirs like /Users are NOT symlinks — the OS reports them as
            //     real directories — so they're correctly kept.)
            //   • Hidden entries (/.vol, /.nofollow, …) are volume-root noise
            //     that the finished list drops as sub-1KB anyway.
            // Filtering both here makes the skeleton a faithful preview.
            if values?.isSymbolicLink == true || values?.isHidden == true { continue }
            let isDirectory = values?.isDirectory ?? false
            let name = url.lastPathComponent
            let item = FolderItem(
                name: name,
                // Built exactly like FileTree.path(of:) builds paths, so
                // SwiftUI can diff skeleton rows against scanned rows.
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
