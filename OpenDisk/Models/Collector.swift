import Foundation
import Observation

/// Holds the files/folders the user has gathered for deletion (the
/// DaisyDisk-style "collector"), reports the running total, and performs the
/// actual removal off the main actor.
@MainActor
@Observable
final class Collector {
    private(set) var items: [CollectedFile] = []
    /// A transient message shown when a macOS-protected path was refused;
    /// the Collector bar surfaces it briefly, then it clears itself.
    private(set) var blockedNotice: String?
    private var noticeTask: Task<Void, Never>?
    /// While a macOS-protected item is being dragged, the reason it can't be
    /// collected. The drop zone reads this to refuse the drop and say "no"
    /// *before* the release, rather than explaining afterwards. Set via
    /// `flagDraggedProtected(_:)` when the drag starts.
    private(set) var draggedProtectedReason: String?
    private var dragNoticeTask: Task<Void, Never>?

    /// Live progress while `deleteAll()` runs, so the tray can show what's
    /// being removed and how much has been freed so far (nil when idle).
    private(set) var deletionProgress: DeletionProgress?

    struct DeletionProgress: Equatable {
        /// Name of the item currently being removed.
        var currentName: String
        /// Items finished so far, out of the total being deleted.
        var completed: Int
        var total: Int
        /// Bytes reclaimed so far.
        var freedBytes: Int64
    }

    /// Snapshots of `items` before each change, so ⌘Z can pull the last
    /// collected item(s) back out. Capped, and cleared once files are actually
    /// deleted (a real deletion can't be undone).
    private var undoStack: [[CollectedFile]] = []
    private static let maxUndo = 50

    var canUndo: Bool { !undoStack.isEmpty }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var formattedTotal: String { ByteFormatter.formatFileSize(totalBytes) }

    // MARK: - Building the collection

    func add(_ files: [CollectedFile]) { recordingUndo { files.forEach(appendOne) } }

    func add(_ file: CollectedFile) { recordingUndo { appendOne(file) } }

    /// Adds one real on-disk entry. Rejects synthetic ("::") rows and
    /// missing paths, de-duplicates, and keeps the set disjoint: an entry
    /// already inside a collected folder is skipped, and collecting a folder
    /// drops any of its now-redundant descendants (so the total never
    /// double-counts, and deletion can't fail on an already-removed child).
    private func appendOne(_ file: CollectedFile) {
        guard !file.path.hasPrefix("::"),
              FileManager.default.fileExists(atPath: file.path),
              !items.contains(where: { $0.path == file.path }) else { return }
        // Never let a macOS-critical location (system folder, home, volume
        // root, …) be collected for deletion.
        if let reason = ProtectedPaths.reason(for: file.path) {
            flagBlocked("“\(file.name)” \(reason)")
            return
        }
        if items.contains(where: { $0.isDirectory && file.path.hasPrefix($0.path + "/") }) { return }
        if file.isDirectory {
            items.removeAll { $0.path.hasPrefix(file.path + "/") }
        }
        items.append(file)
    }

    /// Surfaces a "can't delete this" message for a few seconds.
    private func flagBlocked(_ message: String) {
        blockedNotice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.blockedNotice = nil
        }
    }

    /// Records why the item now being dragged can't be collected, so the tray
    /// can refuse it *before* the drop. Self-clears after a few seconds as a
    /// safety net: SwiftUI doesn't reliably report when a drag preview
    /// disappears, so without this the red "can't delete" banner could get
    /// stuck after the drag ended. Pass `nil` to clear it immediately.
    func flagDraggedProtected(_ reason: String?) {
        dragNoticeTask?.cancel()
        draggedProtectedReason = reason
        guard reason != nil else { return }
        dragNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.draggedProtectedReason = nil
        }
    }

    func remove(_ file: CollectedFile) { recordingUndo { items.removeAll { $0.path == file.path } } }
    func clear() { recordingUndo { items.removeAll() } }

    /// Runs a change, recording the prior collection for undo — but only if
    /// the change actually altered it, so a no-op add (a duplicate or a
    /// protected item) doesn't leave a phantom ⌘Z step.
    private func recordingUndo(_ change: () -> Void) {
        let before = items
        change()
        guard items != before else { return }
        undoStack.append(before)
        if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
    }

    /// ⌘Z: restores the collection to just before the last change — pulls the
    /// last collected item(s) back out.
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        items = previous
    }

    /// Whether a path is collected (so the results list can hide it).
    func contains(path: String) -> Bool { items.contains { $0.path == path } }

    /// The collected paths as a set — build once per render pass, then
    /// filter row arrays with O(1) membership instead of paying
    /// `contains(path:)`'s linear scan per row.
    var pathSet: Set<String> { Set(items.lazy.map(\.path)) }

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
        let total = targets.count
        var freed: Int64 = 0
        var deleted = 0
        var failures: [Failure] = []

        for (index, file) in targets.enumerated() {
            // Announce what's about to be removed, then do the removal off the
            // main actor. The collection is small (a handful of folders), so
            // hopping back per item to publish progress is negligible.
            deletionProgress = DeletionProgress(
                currentName: file.name, completed: index, total: total, freedBytes: freed
            )
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try FileManager.default.removeItem(atPath: file.path); return nil }
                catch { return error.localizedDescription }
            }.value
            if let failure {
                failures.append(Failure(path: file.path, error: failure))
            } else {
                freed += file.size
                deleted += 1
            }
        }

        let failed = Set(failures.map(\.path))
        items.removeAll { !failed.contains($0.path) }
        deletionProgress = nil
        // Deleted files are gone — there's nothing left to undo back into.
        undoStack.removeAll()
        return Result(freedBytes: freed, deletedCount: deleted, failures: failures)
    }
}
