import Darwin
import Foundation
import Synchronization

enum IncrementalUpdater {
    static func apply(
        _ changes: FSEventsChangeJournal.Changes,
        to tree: borrowing Mutex<FileTree>,
        rootPath: String,
        allowedDevices: Set<dev_t>,
        newInodesSince capturedAt: Date,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let reader = BulkDirectoryReader()
        let hardLinks = HardLinkPolicy(
            known: tree.withLock { $0.hardLinkKeys }, capturedAt: capturedAt
        )

        for directoryPath in changes.changedDirectories {
            if isCancelled() { return false }
            let consistent = await updateDirectory(
                at: directoryPath, rootPath: rootPath,
                tree: tree, reader: reader, allowedDevices: allowedDevices,
                hardLinks: hardLinks,
                metrics: metrics, isCancelled: isCancelled
            )
            guard consistent else { return false }
        }

        for subtreePath in changes.subtreesToRescan {
            if isCancelled() { return false }
            let consistent = await rescanSubtree(
                at: subtreePath, rootPath: rootPath,
                tree: tree, allowedDevices: allowedDevices,
                hardLinks: hardLinks,
                metrics: metrics, isCancelled: isCancelled
            )
            guard consistent else { return false }
        }

        guard !isCancelled() else { return false }
        refreshLargeFileSizes(in: tree)
        tree.withLock { $0.normalizeHardLinks() }
        return true
    }

    private static let driftCheckMinimumBytes: Int64 = 64 << 20

    private static func refreshLargeFileSizes(in tree: borrowing Mutex<FileTree>) {
        let candidates = tree.withLock { current in
            current.reachableFiles(allocatedAtLeast: driftCheckMinimumBytes).map {
                (id: $0, path: current.path(of: $0))
            }
        }
        var updates: [(id: FileTree.NodeID, size: Int64)] = []
        for candidate in candidates {
            var info = stat()
            guard lstat(candidate.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                continue
            }
            updates.append((candidate.id, Int64(info.st_blocks) * 512))
        }
        tree.withLock { current in
            for update in updates {
                current.updateAllocatedSize(of: update.id, to: update.size)
            }
        }
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
        hardLinks: HardLinkPolicy,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> Bool {
        guard let node = resolveTarget(at: path, rootPath: rootPath, in: tree) else { return true }

        guard case .contents(let contents, let device) = reader.read(
            directoryAt: path, allowedDevices: allowedDevices
        ) else {
            tree.withLock { $0.removeAllChildren(of: node) }
            return true
        }

        let prefix = path.directoryPrefix
        for file in contents.files where file.linkCount > 1 && file.fileID > 0 {
            let key = FileTree.HardLinkKey(device: device, fileID: file.fileID)
            guard hardLinks.allows(key, at: prefix + file.name) else { return false }
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

        for (name, id) in newSubdirectories {
            if isCancelled() { return true }
            let consistent = await adoptScannedSubtree(
                ofPath: prefix + name, under: id, tree: tree,
                allowedDevices: allowedDevices, hardLinks: hardLinks,
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
        hardLinks: HardLinkPolicy,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> Bool {
        guard let node = resolveTarget(at: path, rootPath: rootPath, in: tree) else { return true }
        tree.withLock { $0.removeAllChildren(of: node) }
        return await adoptScannedSubtree(
            ofPath: path, under: node, tree: tree,
            allowedDevices: allowedDevices, hardLinks: hardLinks,
            metrics: metrics, isCancelled: isCancelled
        )
    }

    private static func adoptScannedSubtree(
        ofPath path: String,
        under node: FileTree.NodeID,
        tree: borrowing Mutex<FileTree>,
        allowedDevices: Set<dev_t>,
        hardLinks: HardLinkPolicy,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let scanned = await TraversalScanner.scan(
            path: path, rootName: path, allowedDevices: allowedDevices,
            metrics: metrics, isCancelled: isCancelled
        )
        for (id, key) in scanned.hardLinkedNodes {
            guard hardLinks.allows(key, at: scanned.path(of: id)) else { return false }
        }
        tree.withLock { current in
            for child in scanned.children(of: FileTree.rootID) {
                current.adoptSubtree(from: scanned, otherNode: child, under: node)
            }
        }
        return true
    }

    private struct HardLinkPolicy {
        let known: Set<FileTree.HardLinkKey>
        let capturedAt: Date

        func allows(_ key: FileTree.HardLinkKey, at path: String) -> Bool {
            known.contains(key) || isCreated(afterCapture: path)
        }

        private func isCreated(afterCapture path: String) -> Bool {
            var info = stat()
            guard lstat(path, &info) == 0 else { return false }
            let birth = Double(info.st_birthtimespec.tv_sec)
                + Double(info.st_birthtimespec.tv_nsec) / 1_000_000_000
            return birth > capturedAt.timeIntervalSince1970
        }
    }
}
