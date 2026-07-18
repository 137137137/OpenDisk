import Darwin
import Foundation

/// Thread-safe cancellation signal shared between the async world and the
/// blocking scan workers.
final class CancellationFlag: Sendable {
    private let state = Locked(false)

    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}

/// The production scanner: picks the fastest strategy per volume and
/// composes the results.
///
/// Strategy selection:
/// - Scanning `/` composes several volumes: the Data volume and the sealed
///   System volume are catalog-scanned in parallel and merged along their
///   firmlink points, and every other volume mounted under
///   `/System/Volumes` (Preboot, VM, Update, ...) is grafted in — matching
///   what "used space on this Mac" actually means on a volume-group system.
/// - Scanning any other volume root (external drives) catalog-scans that
///   volume when it supports `searchfs`.
/// - Subtree rescans and every fallback use the traversal scanner.
///
/// All blocking work runs on dedicated dispatch queues, never on the Swift
/// concurrency cooperative pool.
final class ScanEngine: DiskScanning {

    /// Process-wide tuning, applied once: favor scan I/O and raise the
    /// file-descriptor ceiling for the worker pool.
    private static let processTuning: Void = {
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_IMPORTANT)
        var limits = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limits) == 0 {
            limits.rlim_cur = min(65_536, limits.rlim_max)
            setrlimit(RLIMIT_NOFILE, &limits)
        }
    }()

    private static let dataVolumeMountPoint = "/System/Volumes/Data"
    private static let systemVolumesDirectory = "/System/Volumes"

    func scan(
        path: String,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async -> ScanResult {
        _ = Self.processTuning

        let metrics = ScanMetrics()
        metrics.setTotalUsedBytes(VolumeAttributes.usedBytes(ofVolumeContaining: path))
        let cancellation = CancellationFlag()

        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                onProgress(metrics.snapshot())
            }
        }
        defer {
            progressTask.cancel()
            onProgress(metrics.snapshot())
        }

        let tree = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let tree = Self.performScan(
                        path: path, metrics: metrics, cancellation: cancellation
                    )
                    continuation.resume(returning: tree)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }

        return ScanResult(rootPath: path, tree: tree)
    }

    // MARK: - Blocking scan pipeline

    private static func performScan(
        path: String, metrics: ScanMetrics, cancellation: CancellationFlag
    ) -> FileTree {
        let isCancelled: @Sendable () -> Bool = { cancellation.isCancelled }

        if path == "/" {
            return scanBootVolumeGroup(metrics: metrics, isCancelled: isCancelled)
        }

        var tree = scanVolumeOrTraverse(
            path: path, rootName: path, metrics: metrics, isCancelled: isCancelled
        )
        tree.rollUpDirectorySizes()
        return tree
    }

    /// Catalog-scans `path` when it is the root of a `searchfs`-capable
    /// volume, otherwise (or on any catalog failure) traverses it.
    private static func scanVolumeOrTraverse(
        path: String,
        rootName: String,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> FileTree {
        if VolumeAttributes.isVolumeRoot(path),
           VolumeAttributes.supportsCatalogSearch(atPath: path) {
            do {
                return try CatalogScanner.scanVolume(
                    mountPoint: path, rootName: rootName,
                    metrics: metrics, isCancelled: isCancelled
                )
            } catch CatalogSearchError.cancelled {
                return FileTree(rootName: rootName)
            } catch {
                // Fall through to traversal on any other catalog failure.
            }
        }
        return TraversalScanner.scan(
            path: path, rootName: rootName, metrics: metrics, isCancelled: isCancelled
        )
    }

    /// Composes the boot volume group into one tree rooted at "/".
    private static func scanBootVolumeGroup(
        metrics: ScanMetrics, isCancelled: @escaping @Sendable () -> Bool
    ) -> FileTree {
        let queue = DispatchQueue(
            label: "DiskManager.ScanEngine.volumes",
            qos: .userInitiated,
            attributes: .concurrent
        )
        let group = DispatchGroup()

        let results = Locked<[String: FileTree]>([:])
        func run(_ key: String, _ work: @escaping @Sendable () -> FileTree) {
            queue.async(group: group) {
                let tree = work()
                results.withLock { $0[key] = tree }
            }
        }

        // The System volume: the sealed snapshot mounted at "/". Traversal
        // stays on the system device, so firmlinks into Data, /Volumes and
        // /dev are all cut off automatically.
        run("system") {
            scanVolumeOrTraverse(
                path: "/", rootName: "/", metrics: metrics, isCancelled: isCancelled
            )
        }

        // The Data volume, whose root children (Users, Applications, ...)
        // are exactly the firmlink targets shown at "/".
        run("data") {
            scanVolumeOrTraverse(
                path: dataVolumeMountPoint, rootName: "/",
                metrics: metrics, isCancelled: isCancelled
            )
        }

        // Helper volumes of the group (Preboot, VM, Update, ...): real used
        // space, shown where they live under /System/Volumes.
        let siblingNames = siblingVolumeNames()
        for name in siblingNames {
            let mountPoint = systemVolumesDirectory + "/" + name
            run("sibling:" + name) {
                scanVolumeOrTraverse(
                    path: mountPoint, rootName: mountPoint,
                    metrics: metrics, isCancelled: isCancelled
                )
            }
        }

        group.wait()

        var trees = results.withLock { $0 }
        var merged = trees.removeValue(forKey: "system") ?? FileTree(rootName: "/")
        if let dataTree = trees.removeValue(forKey: "data") {
            merged.merge(dataTree)
        }
        for name in siblingNames {
            guard let siblingTree = trees.removeValue(forKey: "sibling:" + name) else {
                continue
            }
            let components = ["System", "Volumes", name].map { Substring($0) }
            if let target = merged.nodeID(atComponents: components),
               merged.isDirectory(target) {
                merged.merge(siblingTree, into: target)
            }
        }

        // External volumes are separate devices in the sidebar; hide the
        // mount-point stubs from the "/" results.
        merged.removeChild(named: "Volumes", of: FileTree.rootID)

        merged.rollUpDirectorySizes()
        return merged
    }

    /// Names of volumes mounted under /System/Volumes, minus Data (which is
    /// merged into "/" instead of shown in place).
    private static func siblingVolumeNames() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: systemVolumesDirectory
        ) else {
            return []
        }
        return entries.filter { name in
            name != "Data"
                && !name.hasPrefix(".")
                && VolumeAttributes.isVolumeRoot(systemVolumesDirectory + "/" + name)
        }
    }
}
