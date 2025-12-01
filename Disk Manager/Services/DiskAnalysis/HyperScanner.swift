import Foundation
import Darwin

// MARK: - HyperScanner

/// High-performance disk scanner orchestrator.
///
/// This actor coordinates scanning operations using `DiskScanner`
/// for the actual low-level scanning. It handles:
/// - System limit optimization for maximum I/O throughput
/// - Progress reporting to the UI
/// - Scan lifecycle management
actor HyperScanner: ScannerProtocol {
    // Internal state for progress compatibility
    private var scannedBytes: Int64 = 0
    private var itemsScanned: Int = 0

    init() {
        // Request highest I/O priority for scan operations
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_IMPORTANT)
    }

    func scan(url: URL, onProgress: @escaping (HyperScanProgress) -> Void) async -> HyperScanItem {
        // Optimize system limits for maximum throughput
        optimizeSystemLimits()

        // Setup scan context
        let context = ScanContext()
        context.setTotalBytes(getVolumeUsedSize(for: url))
        context.reset()

        // Create scan engine
        let engine = DiskScanner(context: context)

        // Start progress reporting timer
        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                let progress = context.getProgress(currentPath: "")
                onProgress(progress)
                await self?.updateInternalState(bytes: progress.scannedBytes, items: progress.itemsScanned)
            }
        }

        // Run scan
        let result: HyperScanItem
        if url.path == "/" {
            result = await engine.scanRoot()
        } else {
            var statBuf = stat()
            stat(url.path, &statBuf)
            result = await engine.scan(path: url.path, name: url.lastPathComponent, parentDevice: statBuf.st_dev)
        }

        // Stop progress timer
        progressTask.cancel()

        // Final progress update
        let finalProgress = context.getProgress(currentPath: url.path)
        onProgress(finalProgress)

        return result
    }

    // MARK: - Private Methods

    private func updateInternalState(bytes: Int64, items: Int) {
        self.scannedBytes = bytes
        self.itemsScanned = items
    }

    /// Maximize system limits for peak I/O performance.
    private func optimizeSystemLimits() {
        var rlimitData = rlimit()

        // Maximize file descriptors (up to 524288 on macOS)
        if getrlimit(RLIMIT_NOFILE, &rlimitData) == 0 {
            rlimitData.rlim_cur = min(524288, rlimitData.rlim_max)
            if setrlimit(RLIMIT_NOFILE, &rlimitData) != 0 {
                rlimitData.rlim_cur = 65536
                setrlimit(RLIMIT_NOFILE, &rlimitData)
            }
        }

        // Increase stack size for deep directory trees
        if getrlimit(RLIMIT_STACK, &rlimitData) == 0 {
            rlimitData.rlim_cur = 64 * 1024 * 1024  // 64MB
            setrlimit(RLIMIT_STACK, &rlimitData)
        }

        // Request higher process priority
        setpriority(PRIO_PROCESS, 0, -10)
    }

    private func getVolumeUsedSize(for url: URL) -> Int64 {
        var stat = statfs()
        if url.withUnsafeFileSystemRepresentation({ statfs($0, &stat) }) == 0 {
            return (Int64(stat.f_blocks) - Int64(stat.f_bfree)) * Int64(stat.f_bsize)
        }
        return 500_000_000_000  // Default 500GB estimate
    }
}
