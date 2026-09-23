import Darwin
import Foundation
import Synchronization

enum IncrementalUpdater {
    static func apply(
        _ changes: FSEventsChangeJournal.Changes,
        to tree: borrowing Mutex<FileTree>,
        rootPath: String,
        allowedDevices: Set<dev_t>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        let reader = BulkDirectoryReader()

        for directoryPath in changes.changedDirectories {
            if isCancelled() { return false }
            updateDirectory(
                at: directoryPath, rootPath: rootPath,
                tree: tree, reader: reader, allowedDevices: allowedDevices,
                metrics: metrics, isCancelled: isCancelled
            )
        }

        for subtreePath in changes.subtreesToRescan {
            if isCancelled() { return false }
            rescanSubtree(
                at: subtreePath, rootPath: rootPath,
                tree: tree, allowedDevices: allowedDevices,
                metrics: metrics, isCancelled: isCancelled
            )
        }
        return !isCancelled()
    }

    private static func resolveTarget(
        at path: String, rootPath: String, in tree: borrowing Mutex<FileTree>
    ) -> FileTree.NodeID? {
        guard path == rootPath || !VolumeAttributes.isVolumeRoot(path) else { return nil }
        return tree.withLock { current in
            guard let id = current.nodeID(forPath: path, rootPath: rootPath),
                  current.isDirectory(id) else { return nil }
            return id
        }
    }

    private static func updateDirectory(
        at path: String,
        rootPath: String,
        tree: borrowing Mutex<FileTree>,
        reader: BulkDirectoryReader,
        allowedDevices: Set<dev_t>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        guard let node = resolveTarget(at: path, rootPath: rootPath, in: tree) else { return }

        guard case .contents(let contents, _) = reader.read(
            directoryAt: path, allowedDevices: allowedDevices
        ) else {
            tree.withLock { $0.removeAllChildren(of: node) }
            return
        }

        var newSubdirectories: [(name: String, id: FileTree.NodeID)] = []
        var updatedBytes: Int64 = 0

        tree.withLock { current in
            var survivingDirectories: [String: FileTree.NodeID] = [:]
            for child in current.children(of: node) where current.isDirectory(child) {
                survivingDirectories[current.name(of: child)] = child
            }
            current.removeAllChildren(of: node)

            for file in contents.files {
                current.addNode(
                    name: file.name, parent: node, size: file.size, isDirectory: false
                )
                updatedBytes += file.size
            }
            for name in contents.subdirectoryNames {
                if let existing = survivingDirectories[name] {
                    current.link(existing, under: node)
                } else {
                    let id = current.addNode(
                        name: name, parent: node, size: 0, isDirectory: true
                    )
                    newSubdirectories.append((name, id))
                }
            }
            for name in contents.mountPointNames {
                current.addNode(name: name, parent: node, size: 0, isDirectory: true)
            }
        }

        metrics.add(
            bytes: updatedBytes,
            items: contents.files.count + contents.subdirectoryNames.count
        )

        let prefix = path.directoryPrefix
        for (name, id) in newSubdirectories {
            if isCancelled() { return }
            adoptScannedSubtree(
                ofPath: prefix + name, under: id, tree: tree,
                allowedDevices: allowedDevices, metrics: metrics, isCancelled: isCancelled
            )
        }
    }

    private static func rescanSubtree(
        at path: String,
        rootPath: String,
        tree: borrowing Mutex<FileTree>,
        allowedDevices: Set<dev_t>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        guard let node = resolveTarget(at: path, rootPath: rootPath, in: tree) else { return }
        tree.withLock { $0.removeAllChildren(of: node) }
        adoptScannedSubtree(
            ofPath: path, under: node, tree: tree,
            allowedDevices: allowedDevices, metrics: metrics, isCancelled: isCancelled
        )
    }

    private static func adoptScannedSubtree(
        ofPath path: String,
        under node: FileTree.NodeID,
        tree: borrowing Mutex<FileTree>,
        allowedDevices: Set<dev_t>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        let scanned = TraversalScanner.scan(
            path: path, rootName: path, allowedDevices: allowedDevices,
            metrics: metrics, isCancelled: isCancelled
        )
        tree.withLock { current in
            for child in scanned.children(of: FileTree.rootID) {
                current.adoptSubtree(from: scanned, otherNode: child, under: node)
            }
        }
    }
}
