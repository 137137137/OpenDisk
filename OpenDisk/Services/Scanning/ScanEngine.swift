import Darwin
import Foundation
import Synchronization

final class CancellationFlag: Sendable {
    private let state = Atomic(false)

    var isCancelled: Bool { state.load(ordering: .relaxed) }
    func cancel() { state.store(true, ordering: .relaxed) }
}

private final class PartialResultAssembler: Sendable {
    private struct State {
        var providers: [String: PartialTreeProvider] = [:]
        var compose: (@Sendable ([String: FileTree]) -> FileTree)?
    }

    private let state = Mutex(State())

    func register(_ key: String, provider: @escaping PartialTreeProvider) {
        state.withLock { $0.providers[key] = provider }
    }

    func setComposer(_ compose: @escaping @Sendable ([String: FileTree]) -> FileTree) {
        state.withLock { $0.compose = compose }
    }

    func assemble() -> FileTree? {
        let (providers, compose) = state.withLock { ($0.providers, $0.compose) }
        guard let compose, !providers.isEmpty else { return nil }
        return compose(providers.mapValues { $0() })
    }
}

final class ScanEngine: DiskScanning {
    private static let progressInterval: Duration = .milliseconds(33)
    private static let minPartialSnapshotInterval: Duration = .milliseconds(500)
    private static let maxPartialSnapshotInterval: Duration = .seconds(15)
    private static let snapshotBackoffMultiplier = 8

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
        onEvent: @escaping @Sendable (ScanEvent) -> Void
    ) async -> ScanResult {
        _ = Self.processTuning

        let metrics = ScanMetrics()
        let cancellation = CancellationFlag()
        let assembler = PartialResultAssembler()

        let progressTask = Task {
            var lastEmitted: ScanProgress?
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.progressInterval)
                let snapshot = metrics.snapshot()
                guard snapshot != lastEmitted else { continue }
                lastEmitted = snapshot
                onEvent(.progress(snapshot))
            }
        }

        let snapshotQueue = DispatchQueue(
            label: "OpenDisk.ScanEngine.partials", qos: .userInitiated
        )
        let partialTask = Task {
            var sequence = 0
            var interval = Self.minPartialSnapshotInterval
            let clock = ContinuousClock()
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                let assembleStart = clock.now
                let tree: FileTree? = await withCheckedContinuation { continuation in
                    snapshotQueue.async { continuation.resume(returning: assembler.assemble()) }
                }
                interval = min(
                    Self.maxPartialSnapshotInterval,
                    max(
                        Self.minPartialSnapshotInterval,
                        (clock.now - assembleStart) * Self.snapshotBackoffMultiplier
                    )
                )
                guard let tree, !Task.isCancelled else { continue }
                sequence += 1
                onEvent(.partial(PartialScanResult(sequence: sequence, tree: tree)))
            }
        }

        defer {
            progressTask.cancel()
            partialTask.cancel()
            onEvent(.progress(metrics.snapshot()))
        }

        let tree = await withTaskCancellationHandler {
            await Self.performScan(
                path: path, metrics: metrics,
                cancellation: cancellation, assembler: assembler
            )
        } onCancel: {
            cancellation.cancel()
        }

        return ScanResult(
            rootPath: path, tree: tree,
            unreadableDirectories: metrics.unreadableDirectories
        )
    }

    private static let offloadQueue = DispatchQueue(
        label: "OpenDisk.ScanEngine.offload",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private static func offload<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            offloadQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private static func performScan(
        path: String,
        metrics: ScanMetrics,
        cancellation: CancellationFlag,
        assembler: PartialResultAssembler
    ) async -> FileTree {
        let isCancelled: @Sendable () -> Bool = { cancellation.isCancelled }

        if path == "/" {
            return await scanBootVolumeGroup(
                metrics: metrics, isCancelled: isCancelled, assembler: assembler
            )
        }

        let scanPath = resolveDataVolumeAlias(path)
        let subtreeKey = "subtree"
        assembler.setComposer { trees in
            var tree = trees[subtreeKey] ?? FileTree(rootName: path)
            tree.rollUpDirectorySizes()
            return tree
        }

        let scanned = await scanRootTreeUsingCache(
            path: scanPath, rootName: path,
            allowedDevices: subtreeAllowedDevices(forScanRoot: scanPath),
            metrics: metrics, isCancelled: isCancelled,
            registerPartial: { assembler.register(subtreeKey, provider: $0) }
        )
        return await offload {
            var tree = scanned
            tree.rollUpDirectorySizes()
            return tree
        }
    }

    private static func resolveDataVolumeAlias(_ path: String) -> String {
        guard !FileManager.default.fileExists(atPath: path) else { return path }
        let dataPath = dataVolumeMountPoint + path
        return FileManager.default.fileExists(atPath: dataPath) ? dataPath : path
    }

    private static func scanRootTreeUsingCache(
        path: String,
        rootName: String,
        allowedDevices: Set<dev_t>,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool,
        registerPartial: @escaping @Sendable (@escaping PartialTreeProvider) -> Void
    ) async -> FileTree {
        let startEventID = FSEventsChangeJournal.currentEventID

        if let header = ScanCache.peek(forRoot: path) {
            metrics.setPhase(.checkingChanges)
            async let pendingChanges = FSEventsChangeJournal.changes(
                since: header.eventID, under: path,
                timeout: replayTimeBudget(cacheFileBytes: header.fileBytes)
            )
            let cached = await offload { ScanCache.load(forRoot: path) }
            if let cached, cached.tree.name(of: FileTree.rootID) == rootName {
                let live = Mutex(cached.tree)
                registerPartial { live.withLock { $0 } }
                let changes = await pendingChanges
                metrics.setPhase(.scanning)
                if let changes {
                    let applied = await offload {
                        IncrementalUpdater.apply(
                            changes, to: live, rootPath: path,
                            allowedDevices: allowedDevices,
                            metrics: metrics, isCancelled: isCancelled
                        )
                    }
                    if applied {
                        let tree = live.withLock { $0 }
                        saveCacheInBackground(tree: tree, rootPath: path, eventID: startEventID)
                        return tree
                    }
                }
            } else {
                _ = await pendingChanges
                metrics.setPhase(.scanning)
            }
        }

        let tree = await offload {
            traverse(
                path: path, rootName: rootName, allowedDevices: allowedDevices,
                metrics: metrics, isCancelled: isCancelled,
                registerPartial: registerPartial
            )
        }
        if !isCancelled() {
            saveCacheInBackground(tree: tree, rootPath: path, eventID: startEventID)
        }
        return tree
    }

    private static func replayTimeBudget(cacheFileBytes: Int) -> TimeInterval {
        let estimatedFullScanSeconds = Double(cacheFileBytes) / 10_000_000
        return min(4, max(1, estimatedFullScanSeconds / 5))
    }

    private static func saveCacheInBackground(
        tree: FileTree, rootPath: String, eventID: UInt64
    ) {
        DispatchQueue.global(qos: .utility).async {
            ScanCache.save(tree: tree, forRoot: rootPath, eventID: eventID)
        }
    }

    private static func subtreeAllowedDevices(forScanRoot path: String) -> Set<dev_t> {
        guard let rootDevice = VolumeAttributes.deviceID(ofPath: path) else { return [] }
        var devices: Set<dev_t> = [rootDevice]
        if let systemDevice = VolumeAttributes.deviceID(ofPath: "/"),
           rootDevice == systemDevice,
           let dataDevice = VolumeAttributes.deviceID(ofPath: dataVolumeMountPoint) {
            devices.insert(dataDevice)
        }
        return devices
    }

    private static func traverse(
        path: String,
        rootName: String,
        allowedDevices: Set<dev_t>? = nil,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool,
        registerPartial: @escaping @Sendable (@escaping PartialTreeProvider) -> Void = { _ in }
    ) -> FileTree {
        TraversalScanner.scan(
            path: path, rootName: rootName, allowedDevices: allowedDevices,
            workerCount: VolumeAttributes.isVolumeRoot(path)
                ? TraversalScanner.volumeWorkerCount
                : TraversalScanner.subtreeWorkerCount,
            metrics: metrics, isCancelled: isCancelled,
            onPartialTreeAvailable: registerPartial
        )
    }

    private static let rootTreeKey = "root"
    private static func siblingTreeKey(_ name: String) -> String { "sibling:" + name }

    private static func scanBootVolumeGroup(
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool,
        assembler: PartialResultAssembler
    ) async -> FileTree {
        let siblingNames = siblingVolumeNames()
        assembler.setComposer { trees in
            composeBootVolumeGroup(trees, siblingNames: siblingNames)
        }

        let results = Mutex<[String: FileTree]>([:])

        let rootTree = await scanRootTreeUsingCache(
            path: "/", rootName: "/",
            allowedDevices: subtreeAllowedDevices(forScanRoot: "/"),
            metrics: metrics, isCancelled: isCancelled,
            registerPartial: { assembler.register(rootTreeKey, provider: $0) }
        )
        results.withLock { $0[rootTreeKey] = rootTree }

        for name in siblingNames {
            if isCancelled() { break }
            let mountPoint = systemVolumesDirectory + "/" + name
            let tree = await offload {
                traverse(
                    path: mountPoint, rootName: mountPoint,
                    metrics: metrics, isCancelled: isCancelled,
                    registerPartial: { assembler.register(siblingTreeKey(name), provider: $0) }
                )
            }
            results.withLock { $0[siblingTreeKey(name)] = tree }
        }

        return await offload {
            composeBootVolumeGroup(
                results.withLock { $0 }, siblingNames: siblingNames
            )
        }
    }

    private static func composeBootVolumeGroup(
        _ trees: [String: FileTree], siblingNames: [String]
    ) -> FileTree {
        var trees = trees
        var merged = trees.removeValue(forKey: rootTreeKey) ?? FileTree(rootName: "/")
        for name in siblingNames {
            guard let siblingTree = trees.removeValue(forKey: siblingTreeKey(name)) else {
                continue
            }
            let components = ["System", "Volumes", name].map { Substring($0) }
            if let target = merged.nodeID(atComponents: components),
               merged.isDirectory(target) {
                merged.merge(siblingTree, into: target)
            }
        }

        merged.removeChild(named: "Volumes", of: FileTree.rootID)

        merged.rollUpDirectorySizes()
        return merged
    }

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
