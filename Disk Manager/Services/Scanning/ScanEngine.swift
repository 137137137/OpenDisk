import Darwin
import Foundation

/// Thread-safe cancellation signal shared between the async world and the
/// blocking scan workers.
final class CancellationFlag: Sendable {
    private let state = Locked(false)

    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}

/// Assembles displayable snapshots of a scan in flight.
///
/// Scanner components register thread-safe partial-tree providers under
/// stable keys as they start, and the scan plan installs a composer that
/// combines those snapshots exactly the way the final result is composed —
/// so a partial snapshot is always a smaller version of the eventual
/// result, never a differently shaped one.
private final class PartialResultAssembler: @unchecked Sendable {

    private struct State {
        var providers: [String: PartialTreeProvider] = [:]
        var compose: (@Sendable ([String: FileTree]) -> FileTree)?
    }

    private let state = Locked(State())

    func register(_ key: String, provider: @escaping PartialTreeProvider) {
        state.withLock { $0.providers[key] = provider }
    }

    func setComposer(_ compose: @escaping @Sendable ([String: FileTree]) -> FileTree) {
        state.withLock { $0.compose = compose }
    }

    /// Snapshots every registered component and composes them, or nil until
    /// a composer and at least one provider are installed. Blocking (tree
    /// copies plus an O(n) size roll-up): call from a background queue.
    func assemble() -> FileTree? {
        let (providers, compose) = state.withLock { ($0.providers, $0.compose) }
        guard let compose, !providers.isEmpty else { return nil }
        return compose(providers.mapValues { $0() })
    }
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
/// While the scan runs, the engine streams `.partial` snapshots — the
/// same composition applied to whatever each scanner has discovered so
/// far — so the UI can show live, monotonically growing results.
///
/// All blocking work runs on dedicated dispatch queues, never on the Swift
/// concurrency cooperative pool.
final class ScanEngine: DiskScanning {

    /// Cadence of lightweight `.progress` events.
    private static let progressInterval: Duration = .milliseconds(33)
    /// Cadence of `.partial` tree snapshots while the tree is small. Each
    /// snapshot costs an O(n) copy and roll-up of everything scanned so
    /// far (and the next tree mutation pays a copy-on-write duplication),
    /// so as the tree grows the cadence backs off — see the multiplier
    /// below — keeping snapshot overhead a bounded fraction of scan time.
    private static let minPartialSnapshotInterval: Duration = .milliseconds(500)
    /// High ceiling by design: on multi-million-node scans one snapshot
    /// can cost seconds, and a low cap would defeat the overhead bound —
    /// snapshots simply become sparse late in a huge scan, when the
    /// top-level picture has already stabilized anyway.
    private static let maxPartialSnapshotInterval: Duration = .seconds(15)
    /// The next snapshot waits at least this many times the cost of the
    /// last one, bounding worst-case overhead to roughly 1/multiplier of
    /// the scan (assembly time is the best available proxy for the
    /// copy-on-write stall the snapshot also inflicts on scan workers).
    private static let snapshotBackoffMultiplier = 8

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
        onEvent: @escaping @Sendable (ScanEvent) -> Void
    ) async -> ScanResult {
        _ = Self.processTuning

        let metrics = ScanMetrics()
        metrics.setTotalUsedBytes(VolumeAttributes.usedBytes(ofVolumeContaining: path))
        let cancellation = CancellationFlag()
        let assembler = PartialResultAssembler()

        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.progressInterval)
                onEvent(.progress(metrics.snapshot()))
            }
        }

        // Snapshot assembly is real CPU work; run it on its own queue so it
        // never blocks the cooperative pool, and serially so a slow
        // assembly skips ticks instead of piling up.
        let snapshotQueue = DispatchQueue(
            label: "DiskManager.ScanEngine.partials", qos: .userInitiated
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
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let tree = Self.performScan(
                        path: path, metrics: metrics,
                        cancellation: cancellation, assembler: assembler
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
        path: String,
        metrics: ScanMetrics,
        cancellation: CancellationFlag,
        assembler: PartialResultAssembler
    ) -> FileTree {
        let isCancelled: @Sendable () -> Bool = { cancellation.isCancelled }

        if path == "/" {
            return scanBootVolumeGroup(
                metrics: metrics, isCancelled: isCancelled, assembler: assembler
            )
        }

        // Some entries shown at "/" exist only in the Data volume's
        // namespace; translate so rescanning them works, while presenting
        // results under the requested path.
        var scanPath = path
        if !FileManager.default.fileExists(atPath: scanPath) {
            let dataPath = dataVolumeMountPoint + path
            if FileManager.default.fileExists(atPath: dataPath) {
                scanPath = dataPath
            }
        }

        let subtreeKey = "subtree"
        assembler.setComposer { trees in
            var tree = trees[subtreeKey] ?? FileTree(rootName: path)
            tree.rollUpDirectorySizes()
            return tree
        }

        var tree = scanRootTreeUsingCache(
            path: scanPath, rootName: path,
            allowedDevices: subtreeAllowedDevices(forScanRoot: scanPath),
            metrics: metrics, isCancelled: isCancelled,
            registerPartial: { assembler.register(subtreeKey, provider: $0) }
        )
        tree.rollUpDirectorySizes()
        return tree
    }

    // MARK: - Scan cache

    /// Scans `path` through the on-disk cache when possible: a cached
    /// tree plus an FSEvents journal replay turns a repeat scan into a
    /// splice of only the directories that changed since — the cached
    /// tree also appears in full as the very first partial snapshot.
    /// Falls back to (and refreshes the cache from) a full scan whenever
    /// the cache or journal cannot answer reliably.
    private static func scanRootTreeUsingCache(
        path: String,
        rootName: String,
        allowedDevices: Set<dev_t>?,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool,
        registerPartial: (@escaping PartialTreeProvider) -> Void
    ) -> FileTree {
        // Captured before any reading so changes made during this scan
        // replay into the next one.
        let startEventID = FSEventsChangeJournal.currentEventID

        // HFS+ volumes go through the catalog scanner; no cache there.
        let usesCatalog = VolumeAttributes.isVolumeRoot(path)
            && VolumeAttributes.filesystemType(ofVolumeContaining: path) == "hfs"

        if !usesCatalog,
           let cached = ScanCache.load(forRoot: path),
           cached.tree.name(of: FileTree.rootID) == rootName,
           let changes = FSEventsChangeJournal.changes(since: cached.eventID, under: path) {
            let devices = allowedDevices
                ?? VolumeAttributes.deviceID(ofPath: path).map { [$0] } ?? []
            let live = Locked(cached.tree)
            registerPartial { live.withLock { $0 } }
            if IncrementalUpdater.apply(
                changes, to: live, rootPath: path,
                allowedDevices: devices, metrics: metrics, isCancelled: isCancelled
            ) {
                let tree = live.withLock { $0 }
                saveCacheInBackground(tree: tree, rootPath: path, eventID: startEventID)
                return tree
            }
        }

        let tree = scanVolumeOrTraverse(
            path: path, rootName: rootName, allowedDevices: allowedDevices,
            metrics: metrics, isCancelled: isCancelled,
            registerPartial: registerPartial
        )
        if !usesCatalog && !isCancelled() {
            saveCacheInBackground(tree: tree, rootPath: path, eventID: startEventID)
        }
        return tree
    }

    /// Serializing a multi-million-node tree takes hundreds of
    /// milliseconds; keep it off the scan's critical path.
    private static func saveCacheInBackground(
        tree: FileTree, rootPath: String, eventID: UInt64
    ) {
        DispatchQueue.global(qos: .utility).async {
            ScanCache.save(tree: tree, forRoot: rootPath, eventID: eventID)
        }
    }

    /// Devices a subtree scan may descend into: the root's own device,
    /// plus the Data volume when the root sits on the System volume — a
    /// System-side subtree (like /usr with its firmlinked /usr/local) must
    /// compose across the volume group exactly as the live namespace does.
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

    /// Scans one volume or subtree with the fastest measured strategy.
    ///
    /// Strategy, benchmarked on this hardware (4M-entry APFS Data volume):
    /// - APFS: parallel `getattrlistbulk` traversal, ~12.6s. `searchfs`
    ///   measured 27s+ on the same volume (the kernel's APFS catalog walk
    ///   streams only ~150k entries/s regardless of batch size) and worse,
    ///   any concurrent volume mutation aborts it with EBUSY and forces a
    ///   full re-walk — up to 4x on a busy system. The catalog's only
    ///   advantage is seeing entries inside directories the process cannot
    ///   open (~0.3% of items here).
    /// - HFS+ (and anything else advertising `searchfs`): catalog scan —
    ///   on spinning-disk-era HFS+ the catalog walk is roughly an order of
    ///   magnitude faster than traversal, and such volumes are usually
    ///   external/read-mostly, where EBUSY restarts are rare.
    /// - No `searchfs` support (network mounts, exFAT) or subtree rescans:
    ///   traversal.
    ///
    /// `registerPartial` receives the running scanner's partial-tree
    /// provider; on a catalog-to-traversal fallback it is called again and
    /// the later registration must win.
    private static func scanVolumeOrTraverse(
        path: String,
        rootName: String,
        allowedDevices: Set<dev_t>? = nil,
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool,
        registerPartial: (@escaping PartialTreeProvider) -> Void = { _ in }
    ) -> FileTree {
        let isVolumeRoot = VolumeAttributes.isVolumeRoot(path)
        if isVolumeRoot,
           VolumeAttributes.filesystemType(ofVolumeContaining: path) == "hfs",
           VolumeAttributes.supportsCatalogSearch(atPath: path) {
            do {
                return try CatalogScanner.scanVolume(
                    mountPoint: path, rootName: rootName,
                    metrics: metrics, isCancelled: isCancelled,
                    onPartialTreeAvailable: registerPartial
                )
            } catch CatalogSearchError.cancelled {
                return FileTree(rootName: rootName)
            } catch {
                // Fall through to traversal on any other catalog failure.
            }
        }
        return TraversalScanner.scan(
            path: path, rootName: rootName, allowedDevices: allowedDevices,
            workerCount: isVolumeRoot
                ? TraversalScanner.volumeWorkerCount
                : TraversalScanner.subtreeWorkerCount,
            metrics: metrics, isCancelled: isCancelled,
            onPartialTreeAvailable: registerPartial
        )
    }

    // MARK: - Boot volume group

    private static let rootTreeKey = "root"
    private static func siblingTreeKey(_ name: String) -> String { "sibling:" + name }

    /// Composes the boot volume group into one tree rooted at "/".
    private static func scanBootVolumeGroup(
        metrics: ScanMetrics,
        isCancelled: @escaping @Sendable () -> Bool,
        assembler: PartialResultAssembler
    ) -> FileTree {
        let siblingNames = siblingVolumeNames()
        assembler.setComposer { trees in
            composeBootVolumeGroup(trees, siblingNames: siblingNames)
        }

        let results = Locked<[String: FileTree]>([:])

        // One traversal of "/" covers the whole volume group: firmlinks
        // compose the System and Data volumes into the live namespace
        // exactly as the user sees it, and per-entry mount-status cutoffs
        // keep every other volume out — including the booted volume's
        // /Volumes alias and Time Machine local-snapshot mounts, which can
        // share the boot volume's device ID (so a device allowlist alone
        // would count the disk several times over, and scanning the Data
        // volume separately and merging would double-count it the same
        // way). The allowlist still matters on systems where firmlink
        // targets carry the Data volume's distinct device ID.
        // Known omission: housekeeping directories at the Data volume's
        // own root (.Spotlight-V100, .fseventsd, ...) are not firmlinked
        // into "/" and are skipped, matching what the live namespace
        // shows.
        let rootTree = scanRootTreeUsingCache(
            path: "/", rootName: "/",
            allowedDevices: subtreeAllowedDevices(forScanRoot: "/"),
            metrics: metrics, isCancelled: isCancelled,
            registerPartial: { assembler.register(rootTreeKey, provider: $0) }
        )
        results.withLock { $0[rootTreeKey] = rootTree }

        // Helper volumes of the group (Preboot, VM, Update, ...): real used
        // space, shown where they live under /System/Volumes. They are
        // small (well under a second combined) and run after the main
        // volume so reader concurrency never exceeds one worker pool —
        // concurrent pools on one APFS container blow past the kernel-lock
        // contention cliff and slow every scan down.
        for name in siblingNames {
            if isCancelled() { break }
            let mountPoint = systemVolumesDirectory + "/" + name
            let tree = scanVolumeOrTraverse(
                path: mountPoint, rootName: mountPoint,
                metrics: metrics, isCancelled: isCancelled,
                registerPartial: { assembler.register(siblingTreeKey(name), provider: $0) }
            )
            results.withLock { $0[siblingTreeKey(name)] = tree }
        }

        return composeBootVolumeGroup(
            results.withLock { $0 }, siblingNames: siblingNames
        )
    }

    /// Merges per-volume trees into one rolled-up tree rooted at "/".
    /// Used for both the final result and every partial snapshot, so live
    /// results always have the same shape the finished scan will have.
    /// Volumes without a tree yet (a snapshot taken before every scanner
    /// registered) are simply absent from that snapshot.
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
