import Foundation
import Testing
@testable import OpenDisk

@Suite("FileTree compaction")
struct FileTreeCompactionTests {
    private func reachableCount(_ tree: FileTree) -> Int {
        tree.reachabilityBitmap().reduce(0) { $0 + ($1 ? 1 : 0) }
    }

    private func listing(_ tree: FileTree) -> [String] {
        var result: [String] = []
        var stack: [FileTree.NodeID] = [FileTree.rootID]
        while let id = stack.popLast() {
            result.append("\(tree.path(of: id))|\(tree.size(of: id))|\(tree.isDirectory(id))")
            stack.append(contentsOf: tree.children(of: id))
        }
        return result
    }

    private func fragmentedTree() -> FileTree {
        var tree = FileTree(rootName: "/Volumes/T")
        let busy = tree.addNode(name: "busy", parent: FileTree.rootID, size: 0, isDirectory: true)
        let keep = tree.addNode(name: "keep", parent: busy, size: 0, isDirectory: true)
        tree.addNode(name: "inner.bin", parent: keep, size: 7, isDirectory: false)
        for round in 0..<4 {
            tree.removeAllChildren(of: busy)
            for index in 0..<10 {
                tree.addNode(name: "f\(index)", parent: busy, size: Int64(round * 10 + index), isDirectory: false)
            }
            tree.link(keep, under: busy)
        }
        let linked = tree.addNode(name: "link.bin", parent: FileTree.rootID, size: 0, isDirectory: false)
        tree.recordHardLink(linked, key: FileTree.HardLinkKey(device: UInt64(1), fileID: 99), allocatedSize: 4_096)
        return tree
    }

    @Test("drops unreachable nodes and keeps everything reachable")
    func compactsOrphans() {
        var tree = fragmentedTree()
        let before = listing(tree)
        #expect(reachableCount(tree) < tree.nodeCount)

        let compacted = tree.compactIfFragmented()
        #expect(compacted)
        #expect(tree.nodeCount == reachableCount(tree))
        #expect(listing(tree) == before)
        let link = tree.nodeID(atComponents: ["link.bin"])
        #expect(link.flatMap(tree.hardLinkKey(of:)) == FileTree.HardLinkKey(device: UInt64(1), fileID: 99))
    }

    @Test("compaction survives a cache round trip")
    func compactedRoundTrip() throws {
        var tree = fragmentedTree()
        tree.compactIfFragmented()
        let decoded = try #require(FileTree(serializedData: tree.serializedData()))
        #expect(listing(decoded) == listing(tree))
    }

    @Test("leaves lightly fragmented trees alone")
    func belowThreshold() {
        var tree = FileTree(rootName: "/")
        let dir = tree.addNode(name: "d", parent: FileTree.rootID, size: 0, isDirectory: true)
        for index in 0..<20 { tree.addNode(name: "f\(index)", parent: dir, size: 1, isDirectory: false) }
        let orphan = tree.addNode(name: "gone", parent: FileTree.rootID, size: 1, isDirectory: false)
        _ = tree.removeChild(named: "gone", of: FileTree.rootID)
        _ = orphan
        let count = tree.nodeCount
        let compacted = tree.compactIfFragmented()
        #expect(!compacted)
        #expect(tree.nodeCount == count)
    }

    @Test("a tree without garbage is unchanged")
    func noGarbage() {
        var tree = FileTree(rootName: "/")
        tree.addNode(name: "a", parent: FileTree.rootID, size: 1, isDirectory: false)
        let compacted = tree.compactIfFragmented(minimumFraction: 0)
        #expect(!compacted)
        #expect(tree.nodeCount == 2)
    }
}

@Suite("Incremental updates stay compact", .serialized)
struct IncrementalCompactionTests {
    private let fileManager = FileManager.default

    private func withTemporaryTree(_ body: (URL) async throws -> Void) async throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("IncrementalCompactionTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("a/locked").path)
            try? fileManager.removeItem(at: root)
        }
        try await body(root)
    }

    private func write(_ url: URL, bytes: Int) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    private func scan(_ root: URL) async -> FileTree {
        await TraversalScanner.scan(path: root.path, rootName: root.path, metrics: ScanMetrics(), isCancelled: { false })
    }

    private func apply(_ changed: [URL], to tree: FileTree, root: URL) async throws -> FileTree {
        let device = try #require(VolumeAttributes.deviceID(ofPath: root.path))
        let live = Mutex(tree)
        let applied = await IncrementalUpdater.apply(
            FSEventsChangeJournal.Changes(changedDirectories: changed.map(\.path)),
            to: live, rootPath: root.path, allowedDevices: [device],
            newInodesSince: .distantFuture, metrics: ScanMetrics(), isCancelled: { false }
        )
        #expect(applied)
        return live.withLock { $0 }
    }

    private func summary(_ tree: FileTree) -> (total: Int64, paths: Set<String>) {
        var rolled = tree
        rolled.rollUpDirectorySizes()
        var paths = Set<String>()
        var stack: [FileTree.NodeID] = [FileTree.rootID]
        while let id = stack.popLast() {
            paths.insert(rolled.path(of: id))
            stack.append(contentsOf: rolled.children(of: id))
        }
        return (rolled.size(of: FileTree.rootID), paths)
    }

    @Test("repeated re-reads of a busy directory don't grow the tree")
    func busyDirectoryStaysBounded() async throws {
        try await withTemporaryTree { root in
            let busy = root.appendingPathComponent("a/b/busy", isDirectory: true)
            for index in 0..<200 { try write(busy.appendingPathComponent("e\(index)"), bytes: 100) }
            var tree = await scan(root)
            let fresh = tree.nodeCount
            for round in 1...8 {
                try write(busy.appendingPathComponent("e0"), bytes: 100 + round * 4_096)
                tree = try await apply([busy], to: tree, root: root)
                #expect(tree.nodeCount < fresh * 2, "round \(round): \(tree.nodeCount) nodes vs \(fresh) fresh")
            }
            let truth = await scan(root)
            #expect(summary(tree).total == summary(truth).total)
            #expect(summary(tree).paths == summary(truth).paths)
        }
    }

    @Test("add, delete, modify and rename deep in the tree match a full scan after compaction")
    func deepChangesMatchFullScan() async throws {
        try await withTemporaryTree { root in
            let deep = root.appendingPathComponent("a/b/c/d", isDirectory: true)
            for index in 0..<50 { try write(deep.appendingPathComponent("f\(index)"), bytes: 1_000) }
            try write(root.appendingPathComponent("a/b/old/x.bin"), bytes: 5_000)
            var tree = await scan(root)

            try write(deep.appendingPathComponent("added.bin"), bytes: 9_000)
            try fileManager.removeItem(at: deep.appendingPathComponent("f3"))
            try write(deep.appendingPathComponent("f4"), bytes: 70_000)
            try fileManager.moveItem(at: root.appendingPathComponent("a/b/old"), to: root.appendingPathComponent("a/b/new"))

            tree = try await apply([deep, root.appendingPathComponent("a/b")], to: tree, root: root)
            tree.compactIfFragmented(minimumFraction: 0)
            #expect(tree.nodeCount == tree.reachabilityBitmap().filter { $0 }.count)

            let truth = await scan(root)
            #expect(summary(tree).total == summary(truth).total)
            #expect(summary(tree).paths == summary(truth).paths)
        }
    }

    @Test("a directory that becomes unreadable is emptied, and the tree still compacts")
    func permissionError() async throws {
        try await withTemporaryTree { root in
            let locked = root.appendingPathComponent("a/locked", isDirectory: true)
            for index in 0..<40 { try write(locked.appendingPathComponent("f\(index)"), bytes: 2_000) }
            try write(root.appendingPathComponent("a/ok.bin"), bytes: 3_000)
            var tree = await scan(root)

            try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            tree = try await apply([locked], to: tree, root: root)
            tree.compactIfFragmented()

            let lockedID = try #require(tree.nodeID(forPath: locked.path, rootPath: root.path))
            #expect(tree.children(of: lockedID).isEmpty)
            #expect(tree.nodeCount == tree.reachabilityBitmap().filter { $0 }.count)
        }
    }
}
