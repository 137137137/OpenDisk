import Darwin
import Foundation
import Synchronization

enum TraversalScanner {
    static var subtreeWorkerCount: Int {
        min(5, max(3, ProcessInfo.processInfo.activeProcessorCount / 4))
    }

    static var volumeWorkerCount: Int {
        min(8, max(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    private struct WorkItem {
        let directoryID: FileTree.NodeID
        let path: String
    }

    private final class WorkState: Sendable {
        private struct Guarded {
            var stack: [WorkItem] = []
            var pendingDirectories = 0
            var isDrained = false
        }

        private let guarded = Mutex(Guarded())
        private let itemsAvailable = DispatchSemaphore(value: 0)

        func start(with item: WorkItem) {
            guarded.withLock {
                $0.stack.append(item)
                $0.pendingDirectories = 1
            }
            itemsAvailable.signal()
        }

        func push(_ items: [WorkItem]) {
            guard !items.isEmpty else { return }
            guarded.withLock {
                $0.pendingDirectories += items.count
                $0.stack.append(contentsOf: items)
            }
            for _ in items { itemsAvailable.signal() }
        }

        func pop() -> WorkItem? {
            itemsAvailable.wait()
            let item: WorkItem? = guarded.withLock {
                $0.isDrained ? nil : $0.stack.removeLast()
            }
            if item == nil { itemsAvailable.signal() }
            return item
        }

        func completeDirectory() {
            let drained = guarded.withLock {
                $0.pendingDirectories -= 1
                if $0.pendingDirectories == 0 {
                    $0.isDrained = true
                    return true
                }
                return false
            }
            if drained { itemsAvailable.signal() }
        }
    }

    private struct HardLinkKey: Hashable {
        let device: dev_t
        let fileID: UInt64
    }

    static func scan(
        path: String,
        rootName: String,
        allowedDevices: Set<dev_t>? = nil,
        workerCount: Int? = nil,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool,
        onPartialTreeAvailable: (@escaping PartialTreeProvider) -> Void = { _ in }
    ) -> FileTree {
        guard let rootDevice = VolumeAttributes.deviceID(ofPath: path) else {
            metrics.addUnreadable()
            return FileTree(rootName: rootName)
        }
        let devices = (allowedDevices ?? []).union([rootDevice])
        let workerCount = workerCount ?? subtreeWorkerCount

        let tree = Mutex(FileTree(rootName: rootName))
        onPartialTreeAvailable { tree.withLock { $0 } }
        let seenMultiLinkFiles = Mutex(Set<HardLinkKey>())
        let state = WorkState()

        let queue = DispatchQueue(
            label: "OpenDisk.TraversalScanner",
            qos: .userInitiated,
            attributes: .concurrent
        )
        let group = DispatchGroup()

        queue.async {
            state.start(with: WorkItem(directoryID: FileTree.rootID, path: path))
        }

        for _ in 0..<workerCount {
            queue.async(group: group) {
                runWorker(
                    state: state,
                    tree: tree,
                    seenMultiLinkFiles: seenMultiLinkFiles,
                    allowedDevices: devices,
                    metrics: metrics,
                    isCancelled: isCancelled
                )
            }
        }
        group.wait()

        return tree.withLock { $0 }
    }

    private static func runWorker(
        state: WorkState,
        tree: borrowing Mutex<FileTree>,
        seenMultiLinkFiles: borrowing Mutex<Set<HardLinkKey>>,
        allowedDevices: Set<dev_t>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        let reader = BulkDirectoryReader()

        while let item = state.pop() {
            defer { state.completeDirectory() }
            if isCancelled() { continue }

            let outcome = reader.read(
                directoryAt: item.path, allowedDevices: allowedDevices
            )
            guard case .contents(var contents, let device) = outcome else {
                if case .unreadable = outcome { metrics.addUnreadable() }
                continue
            }

            var directoryBytes: Int64 = 0
            for index in contents.files.indices {
                let file = contents.files[index]
                if file.linkCount > 1, file.fileID > 0 {
                    let key = HardLinkKey(device: device, fileID: file.fileID)
                    let firstSighting = seenMultiLinkFiles.withLock {
                        $0.insert(key).inserted
                    }
                    if !firstSighting {
                        contents.files[index] = DirectoryFileEntry(
                            name: file.name, size: 0,
                            fileID: file.fileID, linkCount: file.linkCount
                        )
                        continue
                    }
                }
                directoryBytes += file.size
            }

            let directoryPrefix = item.path.directoryPrefix
            var discovered: [WorkItem] = []
            discovered.reserveCapacity(contents.subdirectoryNames.count)

            tree.withLock { tree in
                for file in contents.files {
                    tree.addNode(
                        name: file.name, parent: item.directoryID,
                        size: file.size, isDirectory: false
                    )
                }
                for name in contents.subdirectoryNames {
                    let id = tree.addNode(
                        name: name, parent: item.directoryID,
                        size: 0, isDirectory: true
                    )
                    discovered.append(WorkItem(directoryID: id, path: directoryPrefix + name))
                }
                for name in contents.mountPointNames {
                    tree.addNode(
                        name: name, parent: item.directoryID,
                        size: 0, isDirectory: true
                    )
                }
            }

            metrics.add(
                bytes: directoryBytes,
                items: contents.files.count + contents.subdirectoryNames.count
                    + contents.mountPointNames.count
            )
            state.push(discovered)
        }
    }
}
