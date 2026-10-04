import Foundation

struct ScanResult: Sendable, Identifiable {
    let rootPath: String
    let tree: FileTree
    var unreadableDirectories: Int = 0
    /// Lets a finished scan drive `.sheet(item:)`.
    let id = UUID()
}

struct PartialScanResult: Sendable {
    let sequence: Int
    let tree: FileTree
}

typealias PartialTreeProvider = @Sendable () -> FileTree

enum ScanEvent: Sendable {
    case progress(ScanProgress)
    case partial(PartialScanResult)
}

protocol DiskScanning: Sendable {
    func scan(
        path: String,
        onEvent: @escaping @Sendable (ScanEvent) -> Void
    ) async -> ScanResult
}
