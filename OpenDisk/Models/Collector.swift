import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class Collector {
    private(set) var items: [CollectedFile] = []
    private(set) var blockedNotice: String?
    private var noticeTask: Task<Void, Never>?
    private(set) var draggedProtectedReason: String?
    private var dragNoticeTask: Task<Void, Never>?

    private(set) var deletionProgress: DeletionProgress?

    static let dropSpace = "collectorDropSpace"
    private(set) var draggingOut: [CollectedFile]?
    @ObservationIgnored var keepZones: [String: CGRect] = [:]
    private var dragOutTask: Task<Void, Never>?

    struct DeletionProgress: Equatable {
        var currentName: String
        var completed: Int
        var total: Int
        var freedBytes: Int64
    }

    private var undoStack: [[CollectedFile]] = []
    private static let maxUndo = 50

    var canUndo: Bool { !undoStack.isEmpty }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var formattedTotal: String { ByteFormatter.formatFileSize(totalBytes) }

    func add(_ files: [CollectedFile]) { recordingUndo { files.forEach(appendOne) } }

    func add(_ file: CollectedFile) { recordingUndo { appendOne(file) } }

    private func appendOne(_ file: CollectedFile) {
        guard !file.path.hasPrefix("::"),
              FileManager.default.fileExists(atPath: file.path),
              !items.contains(where: { $0.path == file.path }) else { return }
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

    private func flagBlocked(_ message: String) {
        blockedNotice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.blockedNotice = nil
        }
    }

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

    func beginDragOut(_ files: [CollectedFile]) {
        dragOutTask?.cancel()
        draggingOut = files.filter { contains(path: $0.path) }
    }

    func endDragOut(operation: NSDragOperation) {
        guard draggingOut != nil else { return }
        guard operation.isEmpty else {
            let pending = draggingOut
            dragOutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.draggingOut == pending else { return }
                self.draggingOut = nil
            }
            return
        }
        resolveDragOut(droppedAt: nil)
    }

    func resolveDragOut(droppedAt location: CGPoint?) {
        dragOutTask?.cancel()
        guard let files = draggingOut else { return }
        draggingOut = nil
        if let location, keepZones.values.contains(where: { $0.contains(location) }) { return }
        let paths = Set(files.map(\.path))
        recordingUndo { items.removeAll { paths.contains($0.path) } }
    }

    func remove(_ file: CollectedFile) { recordingUndo { items.removeAll { $0.path == file.path } } }
    func clear() { recordingUndo { items.removeAll() } }

    private func recordingUndo(_ change: () -> Void) {
        let before = items
        change()
        guard items != before else { return }
        undoStack.append(before)
        if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        items = previous
    }

    func contains(path: String) -> Bool { items.contains { $0.path == path } }

    var pathSet: Set<String> { Set(items.lazy.map(\.path)) }

    struct Failure: Sendable { let path: String; let error: String }
    struct Result: Sendable {
        let freedBytes: Int64
        let deletedCount: Int
        let failures: [Failure]
    }

    func deleteAll() async -> Result {
        let targets = items
        let total = targets.count
        var freed: Int64 = 0
        var deleted = 0
        var failures: [Failure] = []

        for (index, file) in targets.enumerated() {
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
        undoStack.removeAll()
        return Result(freedBytes: freed, deletedCount: deleted, failures: failures)
    }
}
