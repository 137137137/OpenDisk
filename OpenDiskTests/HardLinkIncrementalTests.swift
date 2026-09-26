import Foundation
import Synchronization
import Testing
@testable import OpenDisk

@Suite("Hard links across incremental updates", .serialized)
struct HardLinkIncrementalTests {
    private let fileManager = FileManager.default

    private func withTemporaryTree(_ body: (URL) async throws -> Void) async throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HardLinkIncrementalTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try await body(root)
    }

    private func makeDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func writeFile(_ url: URL, bytes: Int) throws {
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    private func scan(_ root: URL) async -> FileTree {
        await TraversalScanner.scan(
            path: root.path, rootName: root.path,
            metrics: ScanMetrics(), isCancelled: { false }
        )
    }

    private func total(_ tree: FileTree) -> Int64 {
        var rolled = tree
        rolled.rollUpDirectorySizes()
        return rolled.size(of: FileTree.rootID)
    }

    private func applyChanges(
        changedDirectories: [URL] = [],
        subtreesToRescan: [URL] = [],
        to tree: FileTree,
        root: URL
    ) async throws -> (applied: Bool, tree: FileTree) {
        let device = try #require(VolumeAttributes.deviceID(ofPath: root.path))
        let live = Mutex(tree)
        let applied = await IncrementalUpdater.apply(
            FSEventsChangeJournal.Changes(
                changedDirectories: changedDirectories.map(\.path),
                subtreesToRescan: subtreesToRescan.map(\.path)
            ),
            to: live,
            rootPath: root.path,
            allowedDevices: [device],
            metrics: ScanMetrics(),
            isCancelled: { false }
        )
        return (applied, live.withLock { $0 })
    }

    @Test("re-reading a directory with hard links matches a full scan")
    func rereadingDirectoryDoesNotDoubleCount() async throws {
        try await withTemporaryTree { root in
            let other = root.appendingPathComponent("other", isDirectory: true)
            try makeDirectory(other)
            let original = root.appendingPathComponent("original.bin")
            try writeFile(original, bytes: 40_000)
            try fileManager.linkItem(at: original, to: root.appendingPathComponent("sibling-link.bin"))
            try fileManager.linkItem(at: original, to: other.appendingPathComponent("far-link.bin"))
            try writeFile(root.appendingPathComponent("plain.bin"), bytes: 12_000)

            let initial = await scan(root)
            try writeFile(root.appendingPathComponent("touched.bin"), bytes: 4_000)

            let (applied, updated) = try await applyChanges(changedDirectories: [root, other], to: initial, root: root)

            #expect(applied)
            let rescanned = await scan(root)
            #expect(total(updated) == total(rescanned))
        }
    }

    @Test("a new directory holding a link to a known file matches a full scan")
    func newDirectoryWithKnownLink() async throws {
        try await withTemporaryTree { root in
            let original = root.appendingPathComponent("original.bin")
            try writeFile(original, bytes: 40_000)
            try fileManager.linkItem(at: original, to: root.appendingPathComponent("existing-link.bin"))

            let initial = await scan(root)
            let added = root.appendingPathComponent("added", isDirectory: true)
            try makeDirectory(added)
            try fileManager.linkItem(at: original, to: added.appendingPathComponent("new-link.bin"))

            let (applied, updated) = try await applyChanges(changedDirectories: [root], to: initial, root: root)

            #expect(applied)
            let rescanned = await scan(root)
            #expect(total(updated) == total(rescanned))
        }
    }

    @Test("a rescanned subtree does not recount links held elsewhere")
    func rescannedSubtreeMatchesFullScan() async throws {
        try await withTemporaryTree { root in
            let deep = root.appendingPathComponent("deep/er", isDirectory: true)
            try makeDirectory(deep)
            let original = root.appendingPathComponent("original.bin")
            try writeFile(original, bytes: 40_000)
            try fileManager.linkItem(at: original, to: deep.appendingPathComponent("link.bin"))

            let initial = await scan(root)
            let (applied, updated) = try await applyChanges(
                subtreesToRescan: [root.appendingPathComponent("deep")], to: initial, root: root
            )

            #expect(applied)
            let rescanned = await scan(root)
            #expect(total(updated) == total(rescanned))
        }
    }

    @Test("deleting the link that carried the bytes keeps the file counted")
    func removingCountedLinkTransfersBytes() async throws {
        try await withTemporaryTree { root in
            let first = root.appendingPathComponent("first", isDirectory: true)
            let second = root.appendingPathComponent("second", isDirectory: true)
            try makeDirectory(first)
            try makeDirectory(second)
            let a = first.appendingPathComponent("data.bin")
            let b = second.appendingPathComponent("data.bin")
            try writeFile(a, bytes: 40_000)
            try fileManager.linkItem(at: a, to: b)

            let initial = await scan(root)
            let carrier = try #require([a, b].first { url in
                guard let id = initial.nodeID(forPath: url.path, rootPath: root.path) else { return false }
                return initial.size(of: id) > 0
            })
            try fileManager.removeItem(at: carrier)

            let (applied, updated) = try await applyChanges(
                changedDirectories: [carrier.deletingLastPathComponent()], to: initial, root: root
            )

            #expect(applied)
            let rescanned = await scan(root)
            #expect(total(updated) == total(rescanned))
            #expect(total(updated) >= 40_000)
        }
    }

    @Test("a hard link to a file that had one link at scan time falls back to a full scan")
    func unknownHardLinkRequestsFullScan() async throws {
        try await withTemporaryTree { root in
            let sub = root.appendingPathComponent("sub", isDirectory: true)
            try makeDirectory(sub)
            let original = root.appendingPathComponent("original.bin")
            try writeFile(original, bytes: 40_000)

            let initial = await scan(root)
            try fileManager.linkItem(at: original, to: sub.appendingPathComponent("late-link.bin"))

            let (applied, _) = try await applyChanges(changedDirectories: [sub], to: initial, root: root)

            #expect(!applied)
        }
    }

    @Test("hard-link records survive the cache round trip")
    func hardLinksSurviveSerialization() async throws {
        try await withTemporaryTree { root in
            let original = root.appendingPathComponent("original.bin")
            try writeFile(original, bytes: 40_000)
            try fileManager.linkItem(at: original, to: root.appendingPathComponent("link.bin"))

            let scanned = await scan(root)
            let cached = try #require(FileTree(serializedData: scanned.serializedData()))
            let (applied, updated) = try await applyChanges(changedDirectories: [root], to: cached, root: root)

            #expect(applied)
            let rescanned = await scan(root)
            #expect(total(updated) == total(rescanned))
        }
    }

    @Test("trees saved in the previous format are rejected")
    func previousFormatIsRejected() {
        var data = FileTree(rootName: "/").serializedData()
        withUnsafeBytes(of: UInt32(0x444D_5432)) { data.replaceSubrange(0..<4, with: $0) }
        #expect(FileTree(serializedData: data) == nil)
    }
}
