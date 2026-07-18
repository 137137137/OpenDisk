import Foundation
import Darwin

actor HyperScanner: ScannerProtocol {
    private let progressIntervalNanos: UInt64 = 33_000_000

    init() {
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_IMPORTANT)
    }

    func scan(url: URL, onProgress: @escaping (HyperScanProgress) -> Void) async -> HyperScanItem {
        optimizeSystemLimits()

        let context = ScanContext()
        context.setTotalBytes(getVolumeUsedSize(for: url))
        context.reset()

        let engine = DiskScanner(context: context)

        let progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .nanoseconds(self.progressIntervalNanos))
                let progress = context.getProgress(currentPath: "")
                onProgress(progress)
            }
        }

        let result: HyperScanItem
        if url.path == "/" {
            result = await engine.scanRoot()
        } else {
            var statBuf = stat()
            stat(url.path, &statBuf)
            result = await engine.scan(path: url.path, name: url.lastPathComponent, parentDevice: statBuf.st_dev)
        }

        progressTask.cancel()

        let finalProgress = context.getProgress(currentPath: url.path)
        onProgress(finalProgress)

        return result
    }

    private func optimizeSystemLimits() {
        var rlimitData = rlimit()

        if getrlimit(RLIMIT_NOFILE, &rlimitData) == 0 {
            rlimitData.rlim_cur = min(524288, rlimitData.rlim_max)
            if setrlimit(RLIMIT_NOFILE, &rlimitData) != 0 {
                rlimitData.rlim_cur = 65536
                setrlimit(RLIMIT_NOFILE, &rlimitData)
            }
        }

        if getrlimit(RLIMIT_STACK, &rlimitData) == 0 {
            rlimitData.rlim_cur = 64 * 1024 * 1024
            setrlimit(RLIMIT_STACK, &rlimitData)
        }

        setpriority(PRIO_PROCESS, 0, -10)
    }

    private func getVolumeUsedSize(for url: URL) -> Int64 {
        var stat = statfs()
        if url.withUnsafeFileSystemRepresentation({ statfs($0, &stat) }) == 0 {
            return (Int64(stat.f_blocks) - Int64(stat.f_bfree)) * Int64(stat.f_bsize)
        }
        return 500_000_000_000
    }
}
