import Foundation
import Testing
@testable import OpenDisk

/// Integration tests: run the real traversal scanner against a real
/// temporary directory tree.
@Suite("TraversalScanner integration", .serialized)
struct TraversalScannerTests {

    private func withTemporaryTree(
        _ body: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TraversalScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test("counts allocated sizes of a nested tree")
    func scansNestedTree() throws {
        try withTemporaryTree { root in
            let sub = root.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data(count: 4_096).write(to: root.appendingPathComponent("a.bin"))
            try Data(count: 8_192).write(to: sub.appendingPathComponent("b.bin"))

            let metrics = ScanMetrics()
            var tree = TraversalScanner.scan(
                path: root.path, rootName: root.path,
                metrics: metrics, isCancelled: { false }
            )
            tree.rollUpDirectorySizes()

            // Allocated size is at least the logical size (block-rounded).
            #expect(tree.size(of: FileTree.rootID) >= 12_288)
            let subNode = tree.child(of: FileTree.rootID, named: "sub")
            #expect(subNode != nil)
            if let subNode {
                #expect(tree.size(of: subNode) >= 8_192)
                #expect(tree.childCount(of: subNode) == 1)
            }
            #expect(metrics.snapshot().itemsScanned == 3)
        }
    }

    @Test("counts hard-linked files once")
    func hardLinksCountOnce() throws {
        try withTemporaryTree { root in
            let original = root.appendingPathComponent("original.bin")
            try Data(count: 4_096).write(to: original)
            try FileManager.default.linkItem(
                at: original,
                to: root.appendingPathComponent("hardlink.bin")
            )

            let metrics = ScanMetrics()
            var tree = TraversalScanner.scan(
                path: root.path, rootName: root.path,
                metrics: metrics, isCancelled: { false }
            )
            tree.rollUpDirectorySizes()

            #expect(tree.childCount(of: FileTree.rootID) == 2)
            #expect(tree.size(of: FileTree.rootID) < 2 * 4_096 + 1)
        }
    }

    @Test("partial tree provider snapshots match the finished scan")
    func partialProviderSnapshots() throws {
        try withTemporaryTree { root in
            let sub = root.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data(count: 4_096).write(to: sub.appendingPathComponent("a.bin"))

            var provider: PartialTreeProvider?
            var tree = TraversalScanner.scan(
                path: root.path, rootName: root.path,
                metrics: ScanMetrics(), isCancelled: { false },
                onPartialTreeAvailable: { provider = $0 }
            )
            tree.rollUpDirectorySizes()

            // The provider outlives the scan and yields the same content.
            let capturedProvider = try #require(provider)
            var snapshot = capturedProvider()
            snapshot.rollUpDirectorySizes()
            #expect(snapshot.nodeCount == tree.nodeCount)
            #expect(snapshot.size(of: FileTree.rootID) == tree.size(of: FileTree.rootID))
        }
    }

    @Test("cancellation returns quickly with a partial tree")
    func cancellationStops() throws {
        try withTemporaryTree { root in
            for index in 0..<20 {
                let dir = root.appendingPathComponent("dir\(index)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data(count: 512).write(to: dir.appendingPathComponent("f.bin"))
            }

            let metrics = ScanMetrics()
            let tree = TraversalScanner.scan(
                path: root.path, rootName: root.path,
                metrics: metrics, isCancelled: { true }
            )
            // Cancelled before any directory was read: only the root node.
            #expect(tree.nodeCount == 1)
        }
    }
}
