import Foundation
import Darwin

struct FileSystemID: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
}

final class ScanContext: @unchecked Sendable {
    let stats = ScanStatistics()
    let inodeTracker = InodeTracker()

    @inline(__always)
    func addProgress(bytes: Int64, items: Int) {
        stats.add(bytes: bytes, items: items)
    }

    func setTotalBytes(_ bytes: Int64) {
        stats.setTotalBytes(bytes)
    }

    func getProgress(currentPath: String) -> HyperScanProgress {
        stats.snapshot(path: currentPath)
    }

    func reset() {
        stats.reset()
        inodeTracker.reset()
    }

    @inline(__always)
    func visit(inode: FileSystemID) -> Bool {
        return inodeTracker.visit(device: inode.device, inode: inode.inode)
    }
}
