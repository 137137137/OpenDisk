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
    private(set) var isScanning = false
    /// True when a scan of "/" was refused because Full Disk Access is
    /// missing.
    private(set) var needsFullDiskAccess = false
    private(set) var statusDescription = ""
    private(set) var currentScanPath = ""
    private(set) var filesPerSecond = ""
    private(set) var totalDiskScannedBytes: Int64 = 0
    private(set) var scanDuration: TimeInterval = 0

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
        statusDescription = "Preparing scan…"
        currentScanPath = ""
        filesPerSecond = ""
        totalDiskScannedBytes = 0
        scanDuration = 0
        scanRootPath = path
        currentPath = path
        scanResult = nil
        resultIsPartial = false
        lastAppliedPartialSequence = 0
        rootItems = []
        let startDate = Date()

        // Instant skeleton: one shallow directory read shows the top-level
        // names right away, before the scan has produced any numbers.
        Task { [weak self] in
            let items = await Self.skeletonItems(forRoot: path)
            guard let self, self.generation == generation, self.isScanning,
                  self.scanResult == nil else { return }
            self.rootItems = items
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
        guard let node = nodeID(forPath: path) else { return false }
        currentPath = path
        rootItems = folderItems(for: node, limit: displayLimit(for: path))
        return true
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
        }
    }

    private func apply(_ progress: ScanProgress, startedAt: Date) {
        statusDescription = "Scanning: \(ByteFormatter.formatFileSize(progress.scannedBytes)) (\(progress.itemsScanned.formatted()) items)"
        currentScanPath = progress.currentPath
        totalDiskScannedBytes = progress.scannedBytes

        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed > 0 {
            filesPerSecond = "\(Int(Double(progress.itemsScanned) / elapsed).formatted()) files/sec"
        }
    }

    /// Re-materializes the on-screen rows from the current tree, keeping
    /// the user's position. While a partial tree does not contain the
    /// viewed directory yet, whatever is on screen (skeleton or an older
    /// snapshot) stays put rather than flashing empty.
    private func refreshDisplayedItems() {
        if let node = nodeID(forPath: currentPath) {
            rootItems = folderItems(for: node, limit: displayLimit(for: currentPath))
        } else if !resultIsPartial {
            currentPath = scanRootPath
            rootItems = folderItems(for: FileTree.rootID, limit: nil)
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
        if path == result.rootPath { return FileTree.rootID }
        let prefix = result.rootPath.hasSuffix("/") ? result.rootPath : result.rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return result.tree.nodeID(atComponents: path.dropFirst(prefix.count).split(separator: "/"))
    }

    private func folderItems(for node: FileTree.NodeID, limit: Int?) -> [FolderItem] {
        guard let tree = scanResult?.tree, tree.isDirectory(node) else { return [] }
        // Live results keep zero-size entries (their sizes are still
        // arriving); finished results hide sub-1KB noise.
        let minVisibleSize = resultIsPartial ? Int64(-1) : Self.minVisibleSize
        // Sort and trim on node IDs first so only the visible rows ever
        // materialize path strings. Ties break by name so successive live
        // snapshots do not shuffle equal-sized rows.
        return tree.children(of: node)
            .sorted {
                let (a, b) = (tree.size(of: $0), tree.size(of: $1))
                return a == b ? tree.name(of: $0) < tree.name(of: $1) : a > b
            }
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
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: Array(keys)
        ) else {
            return []
        }

        let prefix = path.hasSuffix("/") ? path : path + "/"
        var directories: [FolderItem] = []
        var files: [FolderItem] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
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
