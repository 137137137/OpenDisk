import Foundation
import Observation

/// Holds the files/folders the user has gathered for deletion (the
/// DaisyDisk-style "collector"), reports the running total, and performs the
/// actual removal off the main actor.
@MainActor
@Observable
final class Collector {
    private(set) var items: [CollectedFile] = []

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var formattedTotal: String { ByteFormatter.formatFileSize(totalBytes) }

    // MARK: - Building the collection

    func add(_ files: [CollectedFile]) { files.forEach(add) }

    /// Adds one real on-disk entry. Rejects synthetic ("::") rows and
    /// missing paths, de-duplicates, and keeps the set disjoint: an entry
    /// already inside a collected folder is skipped, and collecting a folder
    /// drops any of its now-redundant descendants (so the total never
    /// double-counts, and deletion can't fail on an already-removed child).
    func add(_ file: CollectedFile) {
        guard !file.path.hasPrefix("::"),
              FileManager.default.fileExists(atPath: file.path),
              !items.contains(where: { $0.path == file.path }) else { return }
        if items.contains(where: { $0.isDirectory && file.path.hasPrefix($0.path + "/") }) { return }
        if file.isDirectory {
            items.removeAll { $0.path.hasPrefix(file.path + "/") }
        }
        items.append(file)
    }

    func remove(_ file: CollectedFile) { items.removeAll { $0.path == file.path } }
    func clear() { items.removeAll() }

    /// Whether a path is collected (so the results list can hide it).
    func contains(path: String) -> Bool { items.contains { $0.path == path } }

    // MARK: - Deletion

    struct Failure: Sendable { let path: String; let error: String }
    struct Result: Sendable {
        let freedBytes: Int64
        let deletedCount: Int
        let failures: [Failure]
    }

    /// PERMANENTLY deletes every collected item (matches the "deleted
    /// forever" countdown and actually reclaims the space). Runs off the
    /// main actor; successfully-removed items are pruned from the list.
    ///
    /// To make deletion recoverable, swap `removeItem(atPath:)` for
    /// `trashItem(at:resultingItemURL:)` — but note the Trash keeps
    /// occupying space until it is emptied, so the "freed" figure would be
    /// aspirational rather than real.
    func deleteAll() async -> Result {
        let targets = items
        let result = await Task.detached(priority: .userInitiated) { () -> Result in
            let fm = FileManager.default
            var freed: Int64 = 0
            var deleted = 0
            var failures: [Failure] = []
            for file in targets {
                do {
                    try fm.removeItem(atPath: file.path)
                    freed += file.size
                    deleted += 1
                } catch {
                    failures.append(Failure(path: file.path, error: error.localizedDescription))
                }
            }
            return Result(freedBytes: freed, deletedCount: deleted, failures: failures)
        }.value

        let failed = Set(result.failures.map(\.path))
        items.removeAll { !failed.contains($0.path) }
        return result
    }
}
