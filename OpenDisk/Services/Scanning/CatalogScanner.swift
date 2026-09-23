import Darwin
import Foundation
import Synchronization

enum CatalogScanner {
    private static let metricsBatchSize = 8_192

    static func scanVolume(
        mountPoint: String,
        rootName: String,
        metrics: ScanMetrics,
        isCancelled: () -> Bool,
        onPartialTreeAvailable: (@escaping PartialTreeProvider) -> Void = { _ in }
    ) throws(CatalogSearchError) -> FileTree {
        let builder = Mutex(CatalogTreeBuilder(rootName: rootName))
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
                    builder.withLock { $0 = CatalogTreeBuilder(rootName: rootName) }
                    metrics.subtract(bytes: flushedBytes + batchBytes,
                                     items: flushedItems + batchItems)
                    (batchBytes, batchItems) = (0, 0)
                    (flushedBytes, flushedItems) = (0, 0)
                },
                body: { entry in
                    guard entry.fileID != CatalogTreeBuilder.volumeRootFileID,
                          entry.fileID > 1 else {
                        return
                    }
                    let countedBytes = builder.withLock { $0.add(entry) }
                    batchBytes += countedBytes
                    batchItems += 1
                    if batchItems >= metricsBatchSize {
                        metrics.add(bytes: batchBytes, items: batchItems)
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
            metrics.add(bytes: batchBytes, items: batchItems)
        }
        return builder.withLock { $0 }.buildTree()
    }
}

struct CatalogTreeBuilder {
    private var tree: FileTree
    private var parentIDs: [UInt64] = []
    private var nodeIDsByFileID: [UInt64: FileTree.NodeID]
    private var countedMultiLinkFileIDs: Set<UInt64> = []

    static let volumeRootFileID: UInt64 = 2

    init(rootName: String) {
        tree = FileTree(rootName: rootName)
        tree.reserveCapacity(1 << 16)
        parentIDs = []
        parentIDs.reserveCapacity(1 << 16)
        nodeIDsByFileID = Dictionary(minimumCapacity: 1 << 16)
        nodeIDsByFileID[Self.volumeRootFileID] = FileTree.rootID
    }

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
