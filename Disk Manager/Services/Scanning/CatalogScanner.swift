import Darwin
import Foundation

/// Whole-volume scanner built on `searchfs(2)`.
///
/// Instead of opening hundreds of thousands of directories, this asks the
/// kernel to walk the volume's catalog B-tree directly and stream back
/// every file and directory with its name, IDs and allocated size — the
/// technique DaisyDisk-class scanners use. The flat entry stream is then
/// reassembled into a `FileTree` from the (fileID, parentID) pairs.
///
/// Only works on volumes advertising `VOL_CAP_INT_SEARCHFS` (APFS, HFS+)
/// and only ever scans a whole volume; callers fall back to
/// `TraversalScanner` on any failure.
enum CatalogScanner {

    /// HFS+ and APFS both use inode 2 for the volume's root directory.
    private static let rootDirectoryFileID: UInt64 = 2
    /// Metrics are flushed once per this many entries, not per entry.
    private static let metricsBatchSize = 8_192

    /// Scans the entire volume mounted at `mountPoint`.
    ///
    /// Blocking: call from a background queue. The returned tree has not
    /// had directory sizes rolled up. Throws `CatalogSearchError` when the
    /// volume cannot be catalog-scanned; the caller should fall back to
    /// traversal.
    static func scanVolume(
        mountPoint: String,
        rootName: String,
        metrics: ScanMetrics,
        isCancelled: () -> Bool
    ) throws -> FileTree {
        var builder = CatalogTreeBuilder(rootName: rootName)

        var batchBytes: Int64 = 0
        var batchItems = 0
        var flushedBytes: Int64 = 0
        var flushedItems = 0

        do {
            try CatalogSearch.enumerateVolume(
                at: mountPoint,
                isCancelled: isCancelled,
                onRestart: {
                    // The catalog changed under a resumed search (EBUSY):
                    // every entry seen so far is invalid.
                    builder = CatalogTreeBuilder(rootName: rootName)
                    metrics.subtract(bytes: flushedBytes + batchBytes,
                                     items: flushedItems + batchItems)
                    (batchBytes, batchItems) = (0, 0)
                    (flushedBytes, flushedItems) = (0, 0)
                },
                body: { entry in
                    guard entry.fileID != rootDirectoryFileID, entry.fileID > 1 else {
                        return
                    }
                    let countedBytes = builder.add(entry)
                    batchBytes += countedBytes
                    batchItems += 1
                    if batchItems >= metricsBatchSize {
                        metrics.add(bytes: batchBytes, items: batchItems,
                                    currentPath: mountPoint)
                        flushedBytes += batchBytes
                        flushedItems += batchItems
                        (batchBytes, batchItems) = (0, 0)
                    }
                }
            )
        } catch {
            metrics.subtract(bytes: flushedBytes + batchBytes,
                             items: flushedItems + batchItems)
            throw error
        }

        if batchItems > 0 {
            metrics.add(bytes: batchBytes, items: batchItems, currentPath: mountPoint)
        }
        return builder.buildTree()
    }
}

/// Reassembles the flat `searchfs` entry stream into a `FileTree`.
///
/// Entries arrive in catalog order (children can precede parents), so nodes
/// are appended unlinked while recording each entry's parent ID; a second
/// pass links every node once the whole volume has streamed.
struct CatalogTreeBuilder {

    private var tree: FileTree
    /// Parent file ID for node i+1 (node 0 is the root).
    private var parentIDs: [UInt64] = []
    private var nodeIDsByFileID: [UInt64: FileTree.NodeID]
    /// File IDs of multi-link files already counted, for HFS+ volumes where
    /// each hard link is a separate catalog record. (APFS reports one
    /// record per inode, so this set stays empty there.)
    private var countedMultiLinkFileIDs: Set<UInt64> = []

    init(rootName: String) {
        tree = FileTree(rootName: rootName)
        tree.reserveCapacity(1 << 16)
        parentIDs = []
        parentIDs.reserveCapacity(1 << 16)
        nodeIDsByFileID = Dictionary(minimumCapacity: 1 << 16)
    }

    /// Adds one catalog entry. Returns the number of bytes this entry
    /// contributes to the scan total (zero for directories and for
    /// already-counted hard links, whose extra names still appear in the
    /// tree at size zero — matching the traversal scanner's behavior).
    mutating func add(_ entry: CatalogEntry) -> Int64 {
        var size = entry.isDirectory ? 0 : entry.size
        if !entry.isDirectory, entry.linkCount > 1,
           !countedMultiLinkFileIDs.insert(entry.fileID).inserted {
            size = 0
        }

        let id = tree.appendUnlinked(
            name: entry.name, size: size, isDirectory: entry.isDirectory
        )
        parentIDs.append(entry.parentID)
        if nodeIDsByFileID[entry.fileID] == nil {
            nodeIDsByFileID[entry.fileID] = id
        }
        return size
    }

    /// Links every node to its parent and returns the finished tree.
    /// Nodes whose parent never appeared (permission-filtered ancestors,
    /// entries that vanished mid-scan) attach to the root so their sizes
    /// still count.
    func buildTree() -> FileTree {
        var result = tree
        let nodeCount = result.nodeCount
        for index in 1..<nodeCount {
            let id = FileTree.NodeID(index)
            let parentID = parentIDs[index - 1]
            var parent = nodeIDsByFileID[parentID] ?? FileTree.rootID
            if parent == id || !result.isDirectory(parent) {
                parent = FileTree.rootID
            }
            result.link(id, under: parent)
        }
        return result
    }
}
