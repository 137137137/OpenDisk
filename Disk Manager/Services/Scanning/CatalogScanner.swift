import Darwin
import Foundation

/// Whole-volume scanner built on `searchfs(2)`.
///
/// Instead of opening hundreds of thousands of directories, this asks the
/// kernel to walk the volume's catalog B-tree directly and stream back
/// every file and directory with its name, IDs and allocated size. The
/// flat entry stream is then reassembled into a `FileTree` from the
/// (fileID, parentID) pairs.
///
/// Used for HFS+ volumes, where the catalog walk is roughly an order of
/// magnitude faster than directory traversal. On APFS it measures ~2x
/// SLOWER than parallel `getattrlistbulk` traversal (~150k entries/s vs
/// ~320k/s on a 4M-entry volume) and any concurrent volume mutation
/// aborts it with EBUSY, so `ScanEngine` prefers traversal there.
///
/// Only works on volumes advertising `VOL_CAP_INT_SEARCHFS` and only ever
/// scans a whole volume; callers fall back to `TraversalScanner` on any
/// failure.
enum CatalogScanner {

    /// HFS+ and APFS both use inode 2 for the volume's root directory.
    private static let rootDirectoryFileID = CatalogTreeBuilder.volumeRootFileID
    /// Metrics are flushed once per this many entries, not per entry.
    private static let metricsBatchSize = 8_192

    /// Scans the entire volume mounted at `mountPoint`.
    ///
    /// Blocking: call from a background queue. The returned tree has not
    /// had directory sizes rolled up. Throws `CatalogSearchError` when the
    /// volume cannot be catalog-scanned; the caller should fall back to
    /// traversal.
    ///
    /// `onPartialTreeAvailable` is called once, before scanning begins,
    /// with a thread-safe provider that snapshots the tree built so far
    /// (entries whose ancestors have not streamed out of the catalog yet
    /// are excluded rather than misplaced; like the final tree, the
    /// snapshot is not yet rolled up).
    static func scanVolume(
        mountPoint: String,
        rootName: String,
        metrics: ScanMetrics,
        isCancelled: () -> Bool,
        onPartialTreeAvailable: (@escaping PartialTreeProvider) -> Void = { _ in }
    ) throws -> FileTree {
        // The builder is mutated only by this thread; the lock exists so
        // snapshot providers can copy it (value semantics, O(1) thanks to
        // copy-on-write) while entries keep streaming.
        let builder = Locked(CatalogTreeBuilder(rootName: rootName))
        onPartialTreeAvailable { builder.withLock { $0 }.buildPartialTree() }

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
                    builder.withLock { $0 = CatalogTreeBuilder(rootName: rootName) }
                    metrics.subtract(bytes: flushedBytes + batchBytes,
                                     items: flushedItems + batchItems)
                    (batchBytes, batchItems) = (0, 0)
                    (flushedBytes, flushedItems) = (0, 0)
                },
                body: { entry in
                    guard entry.fileID != rootDirectoryFileID, entry.fileID > 1 else {
                        return
                    }
                    let countedBytes = builder.withLock { $0.add(entry) }
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
        return builder.withLock { $0 }.buildTree()
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

    /// HFS+ and APFS both use inode 2 for the volume's root directory.
    static let volumeRootFileID: UInt64 = 2

    init(rootName: String) {
        tree = FileTree(rootName: rootName)
        tree.reserveCapacity(1 << 16)
        parentIDs = []
        parentIDs.reserveCapacity(1 << 16)
        nodeIDsByFileID = Dictionary(minimumCapacity: 1 << 16)
        // Entries at the volume's top level carry the root's file ID as
        // their parent; mapping it up front lets partial snapshots link
        // them (the final build would otherwise fall back to the root
        // anyway, but partial linking has no fallback by design).
        nodeIDsByFileID[Self.volumeRootFileID] = FileTree.rootID
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

    /// Links what is linkable so far and returns a displayable snapshot.
    ///
    /// Unlike `buildTree()`, entries whose parent has not streamed out of
    /// the catalog yet stay detached (excluded from totals) instead of
    /// attaching to the root: a live snapshot must not flash transient
    /// orphans at the top level. Because linked-but-detached subtrees are
    /// unreachable from the root, they simply appear once their ancestors
    /// arrive in a later snapshot; sizes only ever grow.
    func buildPartialTree() -> FileTree {
        var result = tree
        let nodeCount = result.nodeCount
        for index in 1..<nodeCount {
            let id = FileTree.NodeID(index)
            guard let parent = nodeIDsByFileID[parentIDs[index - 1]],
                  parent != id, result.isDirectory(parent) else {
                continue
            }
            result.link(id, under: parent)
        }
        return result
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
