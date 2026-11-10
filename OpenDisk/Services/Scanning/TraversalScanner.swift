import Darwin
import Foundation

enum TraversalScanner {
    static var subtreeWorkerCount: Int {
        min(5, max(3, ProcessInfo.processInfo.activeProcessorCount / 4))
    }

    static var volumeWorkerCount: Int {
        min(8, max(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    struct WorkItem: Sendable {
        let directoryID: FileTree.NodeID
        let path: String
    }

    final class WorkState: Sendable {
        private struct Guarded {
            var stack: [WorkItem] = []
            var priority: [WorkItem] = []
            var appliedFocusVersion = 0
            var activeWorkers = 0
            var completion: CheckedContinuation<Void, Never>?

            var pendingCount: Int { stack.count + priority.count }

            mutating func refocus(_ focus: ScanFocus.Snapshot) {
                guard focus.version != appliedFocusVersion else { return }
                appliedFocusVersion = focus.version
                let pending = stack + priority
                stack = pending.filter { !focus.contains($0.path) }
                priority = pending.filter { focus.contains($0.path) }
            }
        }

        private let guarded = Mutex(Guarded())
        private let maxWorkers: Int
        private let focus: ScanFocus?

        init(maxWorkers: Int, focus: ScanFocus? = nil) {
            self.maxWorkers = max(1, maxWorkers)
            self.focus = focus
        }

        func start(with root: WorkItem, completion: CheckedContinuation<Void, Never>) {
            guarded.withLock {
                $0.stack = [root]
                $0.activeWorkers = 1
                $0.completion = completion
            }
        }

        func pop() -> WorkItem? {
            let focus = focus?.snapshot
            let (item, finished) = guarded.withLock { state -> (WorkItem?, CheckedContinuation<Void, Never>?) in
                if let focus { state.refocus(focus) }
                if let item = state.priority.popLast() ?? state.stack.popLast() { return (item, nil) }
                state.activeWorkers -= 1
                guard state.activeWorkers == 0 else { return (nil, nil) }
                defer { state.completion = nil }
                return (nil, state.completion)
            }
            finished?.resume()
            return item
        }

        func push(_ items: [WorkItem]) -> Int {
            guard !items.isEmpty else { return 0 }
            let focus = focus?.snapshot
            return guarded.withLock {
                if let focus, focus.version == $0.appliedFocusVersion, !focus.prefixes.isEmpty {
                    for item in items {
                        if focus.contains(item.path) {
                            $0.priority.append(item)
                        } else {
                            $0.stack.append(item)
                        }
                    }
                } else {
                    $0.stack.append(contentsOf: items)
                }
                let extra = min(maxWorkers - $0.activeWorkers, $0.pendingCount - 1)
                guard extra > 0 else { return 0 }
                $0.activeWorkers += extra
                return extra
            }
        }
    }

    static func scan(
        path: String,
        rootName: String,
        allowedDevices: Set<dev_t>? = nil,
        workerCount: Int? = nil,
        focus: ScanFocus? = nil,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool,
        onPartialTreeAvailable: (@escaping PartialTreeProvider) -> Void = { _ in }
    ) async -> FileTree {
        guard let rootDevice = VolumeAttributes.deviceID(ofPath: path) else {
            metrics.addUnreadable()
            return FileTree(rootName: rootName)
        }
        let devices = (allowedDevices ?? []).union([rootDevice])
        let state = WorkState(maxWorkers: workerCount ?? subtreeWorkerCount, focus: focus)

        let tree = Mutex(FileTree(rootName: rootName))
        onPartialTreeAvailable { tree.withLock { $0 } }
        let seenMultiLinkFiles = Mutex(Set<FileTree.HardLinkKey>())

        let queue = DispatchQueue(
            label: "OpenDisk.TraversalScanner",
            qos: .userInitiated,
            attributes: .concurrent
        )

        @Sendable func launch(_ count: Int) {
            for _ in 0..<count {
                queue.async {
                    runWorker(
                        state: state,
                        tree: tree,
                        seenMultiLinkFiles: seenMultiLinkFiles,
                        allowedDevices: devices,
                        metrics: metrics,
                        isCancelled: isCancelled,
                        launch: launch
                    )
                }
            }
        }

        await withCheckedContinuation { completion in
            state.start(
                with: WorkItem(directoryID: FileTree.rootID, path: path),
                completion: completion
            )
            launch(1)
        }

        return tree.withLock { $0 }
    }

    private static func runWorker(
        state: WorkState,
        tree: borrowing Mutex<FileTree>,
        seenMultiLinkFiles: borrowing Mutex<Set<FileTree.HardLinkKey>>,
        allowedDevices: Set<dev_t>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool,
        launch: (Int) -> Void
    ) {
        let reader = BulkDirectoryReader()

        while let item = state.pop() {
            if isCancelled() { continue }

            let outcome = reader.read(
                directoryAt: item.path, allowedDevices: allowedDevices
            )
            guard case .contents(let contents, let device) = outcome else {
                if case .unreadable = outcome { metrics.addUnreadable() }
                continue
            }

            var directoryBytes: Int64 = 0
            var countedSizes: [Int64] = []
            countedSizes.reserveCapacity(contents.files.count)
            for file in contents.files {
                var size = file.size
                if file.linkCount > 1, file.fileID > 0 {
                    let key = FileTree.HardLinkKey(device: device, fileID: file.fileID)
                    let firstSighting = seenMultiLinkFiles.withLock {
                        $0.insert(key).inserted
                    }
                    if !firstSighting { size = 0 }
                }
                countedSizes.append(size)
                directoryBytes += size
            }

            let directoryPrefix = item.path.directoryPrefix
            var discovered: [WorkItem] = []
            discovered.reserveCapacity(contents.subdirectoryNames.count)

            tree.withLock { tree in
                for (index, file) in contents.files.enumerated() {
                    let id = tree.addNode(
                        name: file.name, parent: item.directoryID,
                        size: countedSizes[index], isDirectory: false
                    )
                    if file.linkCount > 1, file.fileID > 0 {
                        tree.recordHardLink(
                            id,
                            key: FileTree.HardLinkKey(device: device, fileID: file.fileID),
                            allocatedSize: file.size
                        )
                    }
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
            launch(state.push(discovered))
        }
    }
}
