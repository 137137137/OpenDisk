import Foundation
import Testing
@testable import OpenDisk

/// Invariant tests for the Collector's disjoint set of collected files.
/// Everything runs against throwaway trees under the temporary directory —
/// never against real user data.
@MainActor
@Suite("Collector", .serialized)
struct CollectorTests {

    // MARK: - Temp-tree helpers

    /// A fresh, unique directory for one test; callers remove it in a defer.
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CollectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes a small real file and returns its collector entry.
    private func makeFile(_ name: String, in dir: URL, bytes: Int = 4) throws -> CollectedFile {
        let url = dir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return CollectedFile(path: url.path, name: name, size: Int64(bytes), isDirectory: false)
    }

    /// Creates a real subdirectory and returns its collector entry.
    private func makeDir(_ name: String, in dir: URL, size: Int64 = 0) throws -> CollectedFile {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return CollectedFile(path: url.path, name: name, size: size, isDirectory: true)
    }

    // MARK: - Disjointness

    @Test("collecting a folder swallows its already-collected children")
    func parentSwallowsChild() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeDir("dir", in: root, size: 10)
        let child = try makeFile("child.bin", in: dir.url, bytes: 4)

        let collector = Collector()
        collector.add(child)
        collector.add(dir)

        #expect(collector.count == 1)
        #expect(collector.contains(path: dir.path))
        #expect(!collector.contains(path: child.path))
        // The child no longer contributes: only the folder's size counts.
        #expect(collector.totalBytes == 10)
    }

    @Test("adding a child under a collected folder is a no-op")
    func childUnderCollectedParentIgnored() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeDir("dir", in: root, size: 10)
        let child = try makeFile("child.bin", in: dir.url, bytes: 4)

        let collector = Collector()
        collector.add(dir)
        collector.add(child)

        #expect(collector.count == 1)
        #expect(collector.contains(path: dir.path))
        #expect(collector.totalBytes == 10)
        // The no-op add must not have recorded a phantom undo step.
        collector.undo()
        #expect(collector.isEmpty)
        #expect(!collector.canUndo)
    }

    @Test("duplicate adds are ignored and record no undo step")
    func duplicatesIgnored() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile("a.bin", in: root, bytes: 4)

        let collector = Collector()
        collector.add(file)
        collector.add(file)

        #expect(collector.count == 1)
        #expect(collector.totalBytes == 4)
        collector.undo()
        #expect(collector.isEmpty)
        #expect(!collector.canUndo)
    }

    // MARK: - Totals

    @Test("totals track additions and removals")
    func totalsTrackChanges() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try makeFile("a.bin", in: root, bytes: 4)
        let b = try makeFile("b.bin", in: root, bytes: 8)

        let collector = Collector()
        #expect(collector.isEmpty)
        #expect(collector.totalBytes == 0)

        collector.add([a, b])
        #expect(collector.count == 2)
        #expect(collector.totalBytes == 12)

        collector.remove(a)
        #expect(collector.count == 1)
        #expect(collector.totalBytes == 8)
        #expect(!collector.contains(path: a.path))
        #expect(collector.contains(path: b.path))

        collector.clear()
        #expect(collector.isEmpty)
        #expect(collector.totalBytes == 0)
    }

    // MARK: - Undo

    @Test("undo restores the collection one change at a time")
    func undoStepsBack() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try makeFile("a.bin", in: root, bytes: 4)
        let b = try makeFile("b.bin", in: root, bytes: 8)

        let collector = Collector()
        collector.add(a)
        collector.add(b)
        #expect(collector.count == 2)

        collector.undo()
        #expect(collector.count == 1)
        #expect(collector.contains(path: a.path))
        #expect(!collector.contains(path: b.path))

        collector.undo()
        #expect(collector.isEmpty)
        #expect(!collector.canUndo)

        // Undo with nothing recorded is a safe no-op.
        collector.undo()
        #expect(collector.isEmpty)
    }

    @Test("a batch add undoes as a single step")
    func batchAddUndoesAtOnce() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try makeFile("a.bin", in: root, bytes: 4)
        let b = try makeFile("b.bin", in: root, bytes: 8)

        let collector = Collector()
        collector.add([a, b])
        #expect(collector.count == 2)
        collector.undo()
        #expect(collector.isEmpty)
        #expect(!collector.canUndo)
    }

    @Test("removals and clears can be undone")
    func removeAndClearUndo() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try makeFile("a.bin", in: root, bytes: 4)

        let collector = Collector()
        collector.add(a)
        collector.remove(a)
        #expect(collector.isEmpty)
        collector.undo()
        #expect(collector.contains(path: a.path))

        collector.clear()
        #expect(collector.isEmpty)
        collector.undo()
        #expect(collector.count == 1)
    }

    // MARK: - Rejected entries

    @Test("protected paths are refused and surface a notice")
    func protectedPathRefused() throws {
        let collector = Collector()
        collector.add(CollectedFile(path: "/System", name: "System", size: 1, isDirectory: true))

        #expect(collector.isEmpty)
        #expect(collector.blockedNotice?.contains("System") == true)
        #expect(!collector.canUndo)
    }

    @Test("synthetic and nonexistent paths are refused silently")
    func syntheticAndMissingRefused() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("never-created.bin")

        let collector = Collector()
        collector.add(CollectedFile(path: "::synthetic", name: "synthetic", size: 1, isDirectory: false))
        collector.add(CollectedFile(path: missing.path, name: "never-created.bin", size: 1, isDirectory: false))

        #expect(collector.isEmpty)
        #expect(collector.blockedNotice == nil)
        #expect(!collector.canUndo)
    }

    @Test("contains(path:) matches exactly the collected paths")
    func containsPath() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try makeFile("a.bin", in: root, bytes: 4)

        let collector = Collector()
        #expect(!collector.contains(path: a.path))
        collector.add(a)
        #expect(collector.contains(path: a.path))
        #expect(!collector.contains(path: root.path))
    }

    // MARK: - Deletion (temp files only)

    @Test("deleteAll removes temp files, reports totals, and clears undo")
    func deleteAllRemovesTempFiles() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try makeFile("a.bin", in: root, bytes: 4)
        let dir = try makeDir("dir", in: root, size: 8)
        _ = try makeFile("inner.bin", in: dir.url, bytes: 8)

        let collector = Collector()
        collector.add([a, dir])
        #expect(collector.count == 2)

        let result = await collector.deleteAll()

        #expect(result.deletedCount == 2)
        #expect(result.failures.isEmpty)
        #expect(result.freedBytes == 12)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(collector.isEmpty)
        #expect(collector.deletionProgress == nil)
        // A real deletion can't be undone.
        #expect(!collector.canUndo)
    }

    @Test("deleteAll keeps failed items and reports the failure")
    func deleteAllReportsFailures() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try makeFile("a.bin", in: root, bytes: 4)
        let doomed = try makeFile("gone.bin", in: root, bytes: 8)

        let collector = Collector()
        collector.add([a, doomed])
        // Pull the file out from under the collector before deletion runs.
        try FileManager.default.removeItem(at: doomed.url)

        let result = await collector.deleteAll()

        #expect(result.deletedCount == 1)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.path == doomed.path)
        #expect(result.freedBytes == 4)
        // The failed item stays listed; the deleted one is pruned.
        #expect(collector.count == 1)
        #expect(collector.contains(path: doomed.path))
        #expect(!collector.contains(path: a.path))
    }
}
