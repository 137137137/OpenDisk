import Foundation
import Testing
@testable import Disk_Manager

/// Returns a canned tree without touching the filesystem.
private struct FakeScanner: DiskScanning {
    let result: ScanResult

    func scan(
        path: String,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async -> ScanResult {
        onProgress(ScanProgress(
            scannedBytes: result.tree.size(of: FileTree.rootID),
            totalUsedBytes: 1_000_000,
            itemsScanned: result.tree.nodeCount,
            currentPath: path
        ))
        return result
    }
}

@Suite("DiskAnalyzer")
@MainActor
struct DiskAnalyzerTests {

    private static func makeResult(rootPath: String) -> ScanResult {
        var tree = FileTree(rootName: rootPath)
        let docs = tree.addNode(name: "Documents", parent: FileTree.rootID, size: 0, isDirectory: true)
        tree.addNode(name: "report.pdf", parent: docs, size: 50_000, isDirectory: false)
        tree.addNode(name: "movie.mov", parent: FileTree.rootID, size: 2_000_000, isDirectory: false)
        tree.addNode(name: "tiny.txt", parent: FileTree.rootID, size: 10, isDirectory: false)
        tree.rollUpDirectorySizes()
        return ScanResult(rootPath: rootPath, tree: tree)
    }

    @Test("shows scan results sorted largest-first, hiding sub-1KB noise")
    func scanPopulatesSortedItems() async {
        let analyzer = DiskAnalyzer(
            scanner: FakeScanner(result: Self.makeResult(rootPath: "/Volumes/Test"))
        )
        await analyzer.scanDirectory("/Volumes/Test")

        #expect(analyzer.isScanning == false)
        #expect(analyzer.rootItems.map(\.name) == ["movie.mov", "Documents"])
        #expect(analyzer.rootItems.first?.size == 2_000_000)
        #expect(analyzer.rootItems.last?.itemCount == 1)
    }

    @Test("navigates into a directory and back from the completed tree")
    func navigationServesTreeSlices() async {
        let analyzer = DiskAnalyzer(
            scanner: FakeScanner(result: Self.makeResult(rootPath: "/Volumes/Test"))
        )
        await analyzer.scanDirectory("/Volumes/Test")

        analyzer.navigateToPath("/Volumes/Test/Documents")
        #expect(analyzer.rootItems.map(\.name) == ["report.pdf"])
        #expect(analyzer.rootItems.first?.path == "/Volumes/Test/Documents/report.pdf")

        analyzer.navigateToPath("/Volumes/Test")
        #expect(analyzer.rootItems.count == 2)
    }

    @Test("ignores navigation to paths outside the scanned tree")
    func navigationOutsideTreeIsIgnored() async {
        let analyzer = DiskAnalyzer(
            scanner: FakeScanner(result: Self.makeResult(rootPath: "/Volumes/Test"))
        )
        await analyzer.scanDirectory("/Volumes/Test")
        let before = analyzer.rootItems

        analyzer.navigateToPath("/somewhere/else")
        #expect(analyzer.rootItems == before)
    }
}
