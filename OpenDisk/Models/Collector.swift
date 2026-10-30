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

    private var discovered: [String: [CollectedFile]] = [:]
    @ObservationIgnored private var lookups: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var knownSize: (@MainActor (String) -> Int64?)?

    struct RelatedSuggestion: Equatable {
        let files: [CollectedFile]
        var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    private(set) var draggingOut: [CollectedFile]?
    @ObservationIgnored var keepZones: [String: CGRect] = [:]
    private var dragOutTask: Task<Void, Never>?

    struct DeletionProgress: Equatable {
        var disposal: Disposal
        var currentName: String
        var completed: Int
        var total: Int
        var freedBytes: Int64
    }

    enum Disposal: Sendable, Equatable { case delete, trash }

    typealias Trasher = @Sendable (URL) throws -> Void
    private let trasher: Trasher

    init(trasher: @escaping Trasher = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.trasher = trasher
    }

    private var undoStack: [[CollectedFile]] = []
    private static let maxUndo = 50

    var canUndo: Bool { !undoStack.isEmpty }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var formattedTotal: String { ByteFormatter.formatFileSize(totalBytes) }

    func add(_ files: [CollectedFile]) {
        recordingUndo { files.forEach { appendOne($0) } }
        lookUpRelatedFiles()
    }

    func add(_ file: CollectedFile) { add([file]) }

    private func appendOne(_ file: CollectedFile) {
        guard !file.path.hasPrefix("::"),
              FileManager.default.fileExists(atPath: file.path),
              !items.contains(where: { $0.path == file.path }) else { return }
        if let message = ProtectedPaths.message(for: file.path, name: file.name) {
            flagBlocked(message)
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
        removeAll(Set(files.map(\.path)))
    }

    func remove(_ file: CollectedFile) { removeAll([file.path]) }

    func clear() { recordingUndo { items.removeAll() } }

    private func removeAll(_ paths: Set<String>) {
        recordingUndo {
            items.removeAll { paths.contains($0.path) || $0.relatedApp.map(paths.contains) == true }
        }
    }

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
        lookUpRelatedFiles()
    }

    var relatedSuggestions: [String: RelatedSuggestion] {
        guard !discovered.isEmpty else { return [:] }
        let paths = pathSet
        let directories = items.filter(\.isDirectory).map { $0.path + "/" }
        var suggestions: [String: RelatedSuggestion] = [:]
        for app in items where app.isApp {
            guard let found = discovered[app.path] else { continue }
            let suggestion = RelatedSuggestion(files: found.filter { file in
                !paths.contains(file.path) && !directories.contains { file.path.hasPrefix($0) }
            })
            if suggestion.totalBytes > 0 { suggestions[app.path] = suggestion }
        }
        return suggestions
    }

    func addRelatedFiles(for appPath: String) {
        guard let suggestion = relatedSuggestions[appPath] else { return }
        recordingUndo { suggestion.files.forEach(insertRelated) }
    }

    func runningAppNames() -> [String] {
        items.filter(\.isApp).compactMap { app in
            guard let id = RelatedFiles.bundleIdentifier(ofAppAt: app.path),
                  let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
            else { return nil }
            return running.localizedName ?? (app.name as NSString).deletingPathExtension
        }
    }

    var includesAppData: Bool { items.contains { $0.relatedKind?.mayHoldUserData == true } }

    private func insertRelated(_ file: CollectedFile) {
        appendOne(file)
        guard let app = file.relatedApp, items.last?.path == file.path,
              let appIndex = items.firstIndex(where: { $0.path == app }) else { return }
        let added = items.removeLast()
        var index = appIndex + 1
        while index < items.count, items[index].relatedApp == app { index += 1 }
        items.insert(added, at: index)
    }

    private func lookUpRelatedFiles() {
        for app in items where app.isApp && discovered[app.path] == nil && lookups[app.path] == nil {
            let appPath = app.path
            lookups[appPath] = Task { [weak self] in
                let candidates = await Task.detached(priority: .userInitiated) {
                    RelatedFiles.discover(appAt: appPath)
                }.value
                guard let self else { return }
                self.discovered[appPath] = await self.sizedFiles(for: candidates, appPath: appPath)
                self.lookups[appPath] = nil
            }
        }
    }

    private func sizedFiles(for candidates: [RelatedFiles.Candidate], appPath: String) async -> [CollectedFile] {
        guard !candidates.isEmpty else { return [] }
        var sizes: [String: Int64] = [:]
        if let knownSize {
            for candidate in candidates { sizes[candidate.path] = knownSize(candidate.path) }
        }
        let missing = candidates.map(\.path).filter { sizes[$0] == nil }
        if !missing.isEmpty {
            let measured = await Task.detached(priority: .userInitiated) {
                await RelatedFiles.measure(missing)
            }.value
            sizes.merge(measured) { $1 }
        }
        return candidates.map { candidate in
            CollectedFile(
                path: candidate.path,
                name: (candidate.path as NSString).lastPathComponent,
                size: sizes[candidate.path] ?? 0,
                isDirectory: candidate.isDirectory,
                relatedKind: candidate.kind,
                relatedApp: appPath
            )
        }
    }

    func contains(path: String) -> Bool { items.contains { $0.path == path } }

    var pathSet: Set<String> { Set(items.lazy.map(\.path)) }

    struct Failure: Sendable { let path: String; let error: String }
    struct Result: Sendable {
        let disposal: Disposal
        let freedBytes: Int64
        let deletedCount: Int
        let failures: [Failure]
    }

    func deleteAll(_ disposal: Disposal = .delete) async -> Result {
        let targets = items
        let total = targets.count
        var freed: Int64 = 0
        var deleted = 0
        var failures: [Failure] = []

        for (index, file) in targets.enumerated() {
            deletionProgress = DeletionProgress(
                disposal: disposal, currentName: file.name, completed: index, total: total, freedBytes: freed
            )
            let trasher = self.trasher
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    switch disposal {
                    case .delete: try FileManager.default.removeItem(atPath: file.path)
                    case .trash: try trasher(URL(fileURLWithPath: file.path))
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
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
        discovered = discovered.filter { failed.contains($0.key) }
        deletionProgress = nil
        undoStack.removeAll()
        return Result(disposal: disposal, freedBytes: freed, deletedCount: deleted, failures: failures)
    }
}
