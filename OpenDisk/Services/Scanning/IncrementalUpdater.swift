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
        let knownHardLinks = tree.withLock { $0.hardLinkKeys }

        for directoryPath in changes.changedDirectories {
            if isCancelled() { return false }
            let consistent = updateDirectory(
                at: directoryPath, rootPath: rootPath,
                tree: tree, reader: reader, allowedDevices: allowedDevices,
                knownHardLinks: knownHardLinks,
                metrics: metrics, isCancelled: isCancelled
            )
            guard consistent else { return false }
        }

        for subtreePath in changes.subtreesToRescan {
            if isCancelled() { return false }
            let consistent = rescanSubtree(
                at: subtreePath, rootPath: rootPath,
                tree: tree, allowedDevices: allowedDevices,
                knownHardLinks: knownHardLinks,
                metrics: metrics, isCancelled: isCancelled
            )
            guard consistent else { return false }
        }

        guard !isCancelled() else { return false }
        tree.withLock { $0.normalizeHardLinks() }
        return true
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
        knownHardLinks: Set<FileTree.HardLinkKey>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        guard let node = resolveTarget(at: path, rootPath: rootPath, in: tree) else { return true }

        guard case .contents(let contents, let device) = reader.read(
            directoryAt: path, allowedDevices: allowedDevices
        ) else {
            tree.withLock { $0.removeAllChildren(of: node) }
            return true
        }

        for file in contents.files where file.linkCount > 1 && file.fileID > 0 {
            let key = FileTree.HardLinkKey(device: device, fileID: file.fileID)
            if !knownHardLinks.contains(key) { return false }
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
                let id = current.addNode(
                    name: file.name, parent: node, size: file.size, isDirectory: false
                )
                if file.linkCount > 1, file.fileID > 0 {
                    current.recordHardLink(
                        id,
                        key: FileTree.HardLinkKey(device: device, fileID: file.fileID),
                        allocatedSize: file.size
                    )
                }
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
            if isCancelled() { return true }
            let consistent = adoptScannedSubtree(
                ofPath: prefix + name, under: id, tree: tree,
                allowedDevices: allowedDevices, knownHardLinks: knownHardLinks,
                metrics: metrics, isCancelled: isCancelled
            )
            guard consistent else { return false }
        }
        return true
    }

    private static func rescanSubtree(
        at path: String,
        rootPath: String,
        tree: borrowing Mutex<FileTree>,
        allowedDevices: Set<dev_t>,
        knownHardLinks: Set<FileTree.HardLinkKey>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        guard let node = resolveTarget(at: path, rootPath: rootPath, in: tree) else { return true }
        tree.withLock { $0.removeAllChildren(of: node) }
        return adoptScannedSubtree(
            ofPath: path, under: node, tree: tree,
            allowedDevices: allowedDevices, knownHardLinks: knownHardLinks,
            metrics: metrics, isCancelled: isCancelled
        )
    }

    private static func adoptScannedSubtree(
        ofPath path: String,
        under node: FileTree.NodeID,
        tree: borrowing Mutex<FileTree>,
        allowedDevices: Set<dev_t>,
        knownHardLinks: Set<FileTree.HardLinkKey>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        let scanned = TraversalScanner.scan(
            path: path, rootName: path, allowedDevices: allowedDevices,
            metrics: metrics, isCancelled: isCancelled
        )
        guard scanned.hardLinkKeys.isSubset(of: knownHardLinks) else { return false }
        tree.withLock { current in
            for child in scanned.children(of: FileTree.rootID) {
                current.adoptSubtree(from: scanned, otherNode: child, under: node)
            }
        }
        return true
    }
}
