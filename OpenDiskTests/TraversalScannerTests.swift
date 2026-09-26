import Foundation
import Testing
@testable import OpenDisk

@Suite("TraversalScanner integration", .serialized)
struct TraversalScannerTests {
    private func withTemporaryTree(
        _ body: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TraversalScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    @Test("counts allocated sizes of a nested tree")
    func scansNestedTree() async throws {
        try await withTemporaryTree { root in
            let sub = root.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data(count: 4_096).write(to: root.appendingPathComponent("a.bin"))
            try Data(count: 8_192).write(to: sub.appendingPathComponent("b.bin"))

            let metrics = ScanMetrics()
            var tree = await TraversalScanner.scan(
                path: root.path, rootName: root.path,
                metrics: metrics, isCancelled: { false }
            )
            tree.rollUpDirectorySizes()

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
    func hardLinksCountOnce() async throws {
        try await withTemporaryTree { root in
            let original = root.appendingPathComponent("original.bin")
            try Data(count: 4_096).write(to: original)
            try FileManager.default.linkItem(
                at: original,
                to: root.appendingPathComponent("hardlink.bin")
            )

            let metrics = ScanMetrics()
            var tree = await TraversalScanner.scan(
                path: root.path, rootName: root.path,
                metrics: metrics, isCancelled: { false }
            )
            tree.rollUpDirectorySizes()

            #expect(tree.childCount(of: FileTree.rootID) == 2)
            #expect(tree.size(of: FileTree.rootID) < 2 * 4_096 + 1)
        }
    }

    @Test("partial tree provider snapshots match the finished scan")
    func partialProviderSnapshots() async throws {
        try await withTemporaryTree { root in
            let sub = root.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data(count: 4_096).write(to: sub.appendingPathComponent("a.bin"))

            var provider: PartialTreeProvider?
            var tree = await TraversalScanner.scan(
                path: root.path, rootName: root.path,
                metrics: ScanMetrics(), isCancelled: { false },
                onPartialTreeAvailable: { provider = $0 }
            )
            tree.rollUpDirectorySizes()

            let capturedProvider = try #require(provider)
            var snapshot = capturedProvider()
            snapshot.rollUpDirectorySizes()
            #expect(snapshot.nodeCount == tree.nodeCount)
            #expect(snapshot.size(of: FileTree.rootID) == tree.size(of: FileTree.rootID))
        }
    }

    @Test("cancellation returns quickly with a partial tree")
    func cancellationStops() async throws {
        try await withTemporaryTree { root in
            for index in 0..<20 {
                let dir = root.appendingPathComponent("dir\(index)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data(count: 512).write(to: dir.appendingPathComponent("f.bin"))
            }

            let metrics = ScanMetrics()
            let tree = await TraversalScanner.scan(
                path: root.path, rootName: root.path,
                metrics: metrics, isCancelled: { true }
            )
            #expect(tree.nodeCount == 1)
        }
    }

    @Test("many concurrent workers finish exactly once with every item counted")
    func concurrentScanIsComplete() async throws {
        try await withTemporaryTree { root in
            var expectedFiles = 0
            for branch in 0..<40 {
                var dir = root.appendingPathComponent("branch\(branch)", isDirectory: true)
                for depth in 0..<(branch % 6 + 1) {
                    dir = dir.appendingPathComponent("level\(depth)", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    for file in 0..<3 {
                        try Data(count: 100).write(to: dir.appendingPathComponent("f\(file).bin"))
                        expectedFiles += 1
                    }
                }
            }

            var firstTotal: Int64?
            for _ in 0..<25 {
                let metrics = ScanMetrics()
                var tree = await TraversalScanner.scan(
                    path: root.path, rootName: root.path, workerCount: 8,
                    metrics: metrics, isCancelled: { false }
                )
                tree.rollUpDirectorySizes()
                let directories = tree.nodeCount - 1 - expectedFiles
                #expect(directories == 40 + (0..<40).reduce(0) { $0 + $1 % 6 + 1 })
                let total = tree.size(of: FileTree.rootID)
                if let firstTotal { #expect(total == firstTotal) } else { firstTotal = total }
            }
        }
    }
}
