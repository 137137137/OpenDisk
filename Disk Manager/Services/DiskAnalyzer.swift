import Foundation
import Observation

/// Main-actor view model for the analysis screen: runs scans through an
/// injected `DiskScanning` implementation and serves navigable slices of
/// the resulting `FileTree` to the UI.
@MainActor
@Observable
final class DiskAnalyzer {

    /// Only the largest entries of a directory are materialized for
    /// display; navigation into any of them is still exact.
    private static let maxVisibleChildren = 100
    /// Entries at or below this size are noise for a disk-usage view.
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
    private var currentPath = ""
    private var scanTask: Task<ScanResult, Never>?

    init(scanner: any DiskScanning = ScanEngine()) {
        self.scanner = scanner
    }

    // MARK: - Scanning

    /// Scans `path` and shows its contents.
    func scanDirectory(_ path: String) async {
        cancelCurrentScan()

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
        let startDate = Date()

        let scanner = self.scanner
        let task = Task {
            await scanner.scan(path: path) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.apply(progress, startedAt: startDate)
                }
            }
        }
        scanTask = task
        let result = await task.value
        guard scanTask === task else { return }
        scanTask = nil

        scanResult = result
        currentPath = path
        rootItems = folderItems(for: FileTree.rootID)
        scanDuration = Date().timeIntervalSince(startDate)
        isScanning = false
    }

    /// Cancels a scan in flight, if any.
    func cancelCurrentScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Navigation

    /// Shows the contents of `path`, resolved instantly from the completed
    /// scan's tree.
    ///
    /// Returns false when the path is outside the scanned tree (for
    /// example an ancestor of a refreshed subtree); callers should start a
    /// fresh scan of that path instead.
    @discardableResult
    func navigateToPath(_ path: String) -> Bool {
        guard let node = nodeID(forPath: path) else { return false }
        currentPath = path
        rootItems = folderItems(for: node)
        return true
    }

    // MARK: - Private helpers

    private func apply(_ progress: ScanProgress, startedAt: Date) {
        guard isScanning else { return }

        statusDescription = "Scanning: \(ByteFormatter.formatFileSize(progress.scannedBytes)) (\(progress.itemsScanned.formatted()) items)"
        currentScanPath = progress.currentPath
        totalDiskScannedBytes = progress.scannedBytes

        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed > 0 {
            filesPerSecond = "\(Int(Double(progress.itemsScanned) / elapsed).formatted()) files/sec"
        }
    }

    private func nodeID(forPath path: String) -> FileTree.NodeID? {
        guard let result = scanResult else { return nil }
        if path == result.rootPath { return FileTree.rootID }
        let prefix = result.rootPath.hasSuffix("/") ? result.rootPath : result.rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return result.tree.nodeID(atComponents: path.dropFirst(prefix.count).split(separator: "/"))
    }

    private func folderItems(for node: FileTree.NodeID) -> [FolderItem] {
        guard let tree = scanResult?.tree, tree.isDirectory(node) else { return [] }
        // Sort and trim on node IDs first so only the visible rows ever
        // materialize path strings.
        return tree.children(of: node)
            .sorted { tree.size(of: $0) > tree.size(of: $1) }
            .prefix(Self.maxVisibleChildren)
            .filter { tree.size(of: $0) > Self.minVisibleSize }
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
}
