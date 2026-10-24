import Foundation
import Testing
@testable import OpenDisk

private struct FakeScanner: DiskScanning {
    let result: ScanResult

    func scan(
        path: String,
        onEvent: @escaping @Sendable (ScanEvent) -> Void
    ) async -> ScanResult {
        onEvent(.progress(ScanProgress(
            scannedBytes: result.tree.size(of: FileTree.rootID),
            itemsScanned: result.tree.nodeCount
        )))
        return result
    }
}

private final class GatedScanner: DiskScanning, Sendable {
    private let partialTree: FileTree?
    private let finalResult: ScanResult
    private let stream: AsyncStream<Void>
    private let releaseGate: @Sendable () -> Void

    init(partial: FileTree?, final: ScanResult) {
        partialTree = partial
        finalResult = final
        var continuation: AsyncStream<Void>.Continuation!
        stream = AsyncStream { continuation = $0 }
        let captured = continuation!
        releaseGate = { captured.finish() }
    }

    func release() { releaseGate() }

    func scan(
        path: String,
        onEvent: @escaping @Sendable (ScanEvent) -> Void
    ) async -> ScanResult {
        if let partialTree {
            onEvent(.partial(PartialScanResult(sequence: 1, tree: partialTree)))
        }
        for await _ in stream {}
        return finalResult
    }
}

private final class RescanGatedScanner: DiskScanning, Sendable {
    private let result: ScanResult
    private let scans = Mutex(0)
    private let gate: GatedScanner

    init(result: ScanResult) {
        self.result = result
        gate = GatedScanner(partial: nil, final: result)
    }

    func release() { gate.release() }

    func scan(
        path: String,
        onEvent: @escaping @Sendable (ScanEvent) -> Void
    ) async -> ScanResult {
        let index = scans.withLock { count in
            count += 1
            return count
        }
        if index == 1 { return result }
        return await gate.scan(path: path, onEvent: onEvent)
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

    private func waitUntil(
        _ condition: @MainActor () -> Bool, timeout: Duration = .seconds(5)
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
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

    @Test("streams partial results while the scan is still running")
    func partialResultsAppearMidScan() async {
        var partial = FileTree(rootName: "/Volumes/Test")
        partial.addNode(name: "Documents", parent: FileTree.rootID, size: 0, isDirectory: true)
        partial.addNode(name: "movie.mov", parent: FileTree.rootID, size: 900_000, isDirectory: false)
        partial.rollUpDirectorySizes()

        let scanner = GatedScanner(
            partial: partial, final: Self.makeResult(rootPath: "/Volumes/Test")
        )
        let analyzer = DiskAnalyzer(scanner: scanner)

        async let scanCompleted: Void = analyzer.scanDirectory("/Volumes/Test")
        await waitUntil { !analyzer.rootItems.isEmpty }

        #expect(analyzer.isScanning)
        #expect(analyzer.rootItems.map(\.name) == ["movie.mov", "Documents"])
        #expect(analyzer.rootItems.first?.size == 900_000)

        scanner.release()
        await scanCompleted

        #expect(analyzer.isScanning == false)
        #expect(analyzer.rootItems.first?.size == 2_000_000)
        #expect(analyzer.scanDuration > 0)
    }

    @Test("hides tiny files and hidden empty folders in partial results, keeps unsized folders")
    func partialResultsHideNoise() async {
        var partial = FileTree(rootName: "/Volumes/Test")
        partial.addNode(name: "Documents", parent: FileTree.rootID, size: 0, isDirectory: true)
        partial.addNode(name: ".vol", parent: FileTree.rootID, size: 0, isDirectory: true)
        partial.addNode(name: ".file", parent: FileTree.rootID, size: 0, isDirectory: false)
        partial.addNode(name: "tiny.txt", parent: FileTree.rootID, size: 10, isDirectory: false)
        partial.addNode(name: "movie.mov", parent: FileTree.rootID, size: 900_000, isDirectory: false)
        partial.rollUpDirectorySizes()

        let scanner = GatedScanner(
            partial: partial, final: Self.makeResult(rootPath: "/Volumes/Test")
        )
        let analyzer = DiskAnalyzer(scanner: scanner)

        async let scanCompleted: Void = analyzer.scanDirectory("/Volumes/Test")
        await waitUntil { !analyzer.rootItems.isEmpty }

        #expect(analyzer.rootItems.map(\.name) == ["movie.mov", "Documents"])

        scanner.release()
        await scanCompleted
    }

    @Test("keeps the previous results and chart visible while rescanning the same location")
    func rescanKeepsPreviousResults() async {
        let scanner = RescanGatedScanner(result: Self.makeResult(rootPath: "/Volumes/Test"))
        let analyzer = DiskAnalyzer(scanner: scanner)
        await analyzer.scanDirectory("/Volumes/Test")
        await waitUntil { analyzer.chartRoot != nil }
        let before = analyzer.rootItems

        async let rescanCompleted: Void = analyzer.scanDirectory("/Volumes/Test")
        await waitUntil { analyzer.isScanning }

        #expect(analyzer.isScanning)
        #expect(analyzer.rootItems == before)
        #expect(analyzer.chartRoot != nil)

        scanner.release()
        await rescanCompleted
        #expect(analyzer.isScanning == false)
        #expect(analyzer.rootItems == before)
    }

    @Test("shows a skeleton of top-level names before any scan data arrives")
    func skeletonAppearsBeforeScanData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskAnalyzerSkeleton-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Stuff", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(count: 4_096).write(to: root.appendingPathComponent("file.bin"))
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = GatedScanner(
            partial: nil,
            final: ScanResult(rootPath: root.path, tree: FileTree(rootName: root.path))
        )
        let analyzer = DiskAnalyzer(scanner: scanner)

        async let scanCompleted: Void = analyzer.scanDirectory(root.path)
        await waitUntil { !analyzer.rootItems.isEmpty }

        #expect(analyzer.isScanning)
        #expect(analyzer.rootItems.map(\.name) == ["Stuff", "file.bin"])
        #expect(analyzer.rootItems.first?.sizeIsKnown == false)
        #expect(analyzer.rootItems.last?.sizeIsKnown == true)

        scanner.release()
        await scanCompleted
        #expect(analyzer.isScanning == false)
    }

    @Test("search finds entries anywhere in the finished tree")
    func searchFindsNestedEntries() async {
        let analyzer = DiskAnalyzer(
            scanner: FakeScanner(result: Self.makeResult(rootPath: "/Volumes/Test"))
        )
        await analyzer.scanDirectory("/Volumes/Test")

        analyzer.updateSearch(query: "REPORT", scope: .all)
        await waitUntil { !analyzer.searchResults.isEmpty }

        #expect(analyzer.searchResults.map(\.name) == ["report.pdf"])
        #expect(analyzer.searchResults.first?.path == "/Volumes/Test/Documents/report.pdf")
        #expect(analyzer.searchResultsArePartial == false)
        #expect(analyzer.isSearchRunning == false)

        analyzer.updateSearch(query: "tiny", scope: .all)
        await waitUntil { analyzer.searchResults.first?.name == "tiny.txt" }
        #expect(analyzer.searchTotalMatches == 1)

        analyzer.updateSearch(query: "", scope: .all)
        #expect(analyzer.searchResults.isEmpty)
        #expect(analyzer.searchTotalMatches == 0)
    }

    @Test("mid-scan search answers from the partial tree, then refines")
    func searchDuringScanUsesPartialThenFinal() async {
        var partial = FileTree(rootName: "/Volumes/Test")
        partial.addNode(name: "movie.mov", parent: FileTree.rootID, size: 900_000, isDirectory: false)
        partial.rollUpDirectorySizes()

        let scanner = GatedScanner(
            partial: partial, final: Self.makeResult(rootPath: "/Volumes/Test")
        )
        let analyzer = DiskAnalyzer(scanner: scanner)

        async let scanCompleted: Void = analyzer.scanDirectory("/Volumes/Test")
        await waitUntil { !analyzer.rootItems.isEmpty }

        analyzer.updateSearch(query: "movie", scope: .all)
        await waitUntil { !analyzer.searchResults.isEmpty }
        #expect(analyzer.searchResultsArePartial)
        #expect(analyzer.searchResults.first?.size == 900_000)

        analyzer.updateSearch(query: "report", scope: .files)
        await waitUntil { analyzer.isSearchRunning == false }
        #expect(analyzer.searchResults.isEmpty)

        scanner.release()
        await scanCompleted

        await waitUntil { !analyzer.searchResults.isEmpty }
        #expect(analyzer.searchResults.map(\.name) == ["report.pdf"])
        #expect(analyzer.searchResultsArePartial == false)
    }
}
