import Darwin
import Foundation

/// Recursive-descent scanner built on `getattrlistbulk(2)`.
///
/// Used for subtree scans and for volumes that cannot be catalog-scanned
/// (network mounts, exFAT, or any `searchfs` failure).
///
/// Architecture: a fixed pool of blocking workers on a dedicated concurrent
/// dispatch queue, pulling directories from one shared LIFO work stack.
/// Compared to spawning a Swift concurrency child task per directory this
/// removes millions of task allocations and actor hops per scan, and it
/// keeps blocking syscalls off the cooperative thread pool entirely (which
/// otherwise starves the whole app's async work — the cooperative pool
/// never grows to cover blocked threads).
///
/// The scan never leaves its allowlisted devices: every opened directory's
/// `st_dev` is checked, which uniformly cuts off mount points and virtual
/// filesystems with no hardcoded path lists. Scans rooted on the System
/// volume also allowlist the Data volume, so firmlinks compose exactly as
/// the live namespace does.
enum TraversalScanner {

    /// In-flight directory reads. Modern APFS tolerates far more than the
    /// historically feared ~8 concurrent readers (the 2018-era kernel-lock
    /// contention was halved in Mojave); fast scanners run 2-3x cores.
    /// Capped because beyond a few dozen readers syscall latency, not
    /// parallelism, dominates.
    static var workerCount: Int {
        min(32, max(8, ProcessInfo.processInfo.activeProcessorCount * 2))
    }

    private struct WorkItem {
        let directoryID: FileTree.NodeID
        let path: String
    }

    /// Shared scan state. A blocked `pop` parks on the semaphore; the
    /// mutex only guards short push/pop critical sections, so contention
    /// stays negligible next to the ~10-100 us directory syscalls.
    private final class WorkState: @unchecked Sendable {
        private struct Guarded {
            var stack: [WorkItem] = []
            /// Directories discovered but not yet fully processed. The scan
            /// is complete exactly when this returns to zero.
            var pendingDirectories = 0
            var isDrained = false
        }

        private let guarded = Locked(Guarded())
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

        /// Blocks until an item is available. Returns nil once the scan has
        /// drained; the drain signal cascades so every worker wakes.
        func pop() -> WorkItem? {
            itemsAvailable.wait()
            let item: WorkItem? = guarded.withLock {
                $0.isDrained ? nil : $0.stack.removeLast()
            }
            if item == nil { itemsAvailable.signal() }
            return item
        }

        /// Marks one directory fully processed; the last one out flips the
        /// drained flag and starts the wake-up cascade.
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

    /// Hard links never span volumes, but a multi-device scan must not let
    /// equal file IDs from different volumes collide.
    private struct HardLinkKey: Hashable {
        let device: dev_t
        let fileID: UInt64
    }

    /// Scans the subtree rooted at `path`, descending only into directories
    /// on `allowedDevices` (default: the root path's own device).
    ///
    /// Blocking: call from a background queue, never the main thread or the
    /// cooperative pool. The returned tree has not had directory sizes
    /// rolled up yet (callers merge trees first, then roll up once).
    static func scan(
        path: String,
        rootName: String,
        allowedDevices: Set<dev_t>? = nil,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> FileTree {
        guard let rootDevice = VolumeAttributes.deviceID(ofPath: path) else {
            return FileTree(rootName: rootName)
        }
        let devices = (allowedDevices ?? []).union([rootDevice])

        let tree = Locked(FileTree(rootName: rootName))
        let seenMultiLinkFiles = Locked(Set<HardLinkKey>())
        let state = WorkState()
        state.start(with: WorkItem(directoryID: FileTree.rootID, path: path))

        let queue = DispatchQueue(
            label: "DiskManager.TraversalScanner",
            qos: .userInitiated,
            attributes: .concurrent
        )
        let group = DispatchGroup()

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
        tree: Locked<FileTree>,
        seenMultiLinkFiles: Locked<Set<HardLinkKey>>,
        allowedDevices: Set<dev_t>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        let reader = BulkDirectoryReader()

        while let item = state.pop() {
            defer { state.completeDirectory() }
            if isCancelled() { continue }

            guard case .contents(var contents, let device) = reader.read(
                directoryAt: item.path, allowedDevices: allowedDevices
            ) else {
                continue
            }

            // Hard-linked files (nlink > 1) are the only entries that can be
            // double-counted, so only those pay for dedup tracking.
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

            let directoryPrefix = item.path.hasSuffix("/") ? item.path : item.path + "/"
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
            }

            metrics.add(
                bytes: directoryBytes,
                items: contents.files.count + contents.subdirectoryNames.count,
                currentPath: item.path
            )
            state.push(discovered)
        }
    }
}
