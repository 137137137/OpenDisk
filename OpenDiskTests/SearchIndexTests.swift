import Foundation
import Testing
@testable import OpenDisk

@Suite("Search index")
struct SearchIndexTests {

    /// A small tree with files and folders at several depths:
    /// /Volumes/T/{Documents/{Report Final.pdf, drafts/{report-old.PDF}},
    ///             Caches/, movie.mov}
    private func makeTree() -> FileTree {
        var tree = FileTree(rootName: "/Volumes/T")
        let docs = tree.addNode(name: "Documents", parent: FileTree.rootID, size: 0, isDirectory: true)
        tree.addNode(name: "Report Final.pdf", parent: docs, size: 900, isDirectory: false)
        let drafts = tree.addNode(name: "drafts", parent: docs, size: 0, isDirectory: true)
        tree.addNode(name: "report-old.PDF", parent: drafts, size: 300, isDirectory: false)
        tree.addNode(name: "Caches", parent: FileTree.rootID, size: 0, isDirectory: true)
        tree.addNode(name: "movie.mov", parent: FileTree.rootID, size: 2_000, isDirectory: false)
        tree.rollUpDirectorySizes()
        return tree
    }

    @Test("case-insensitive name match, largest first, with real paths")
    func basicMatch() async {
        let index = SearchIndex(tree: makeTree())
        let results = await index.search(query: "rEpOrT", scope: .all)
        #expect(results.totalMatches == 2)
        #expect(results.items.map(\.name) == ["Report Final.pdf", "report-old.PDF"])
        #expect(results.items.first?.path == "/Volumes/T/Documents/Report Final.pdf")
        #expect(results.items.first?.size == 900)
    }

    @Test("scope narrows to folders or files")
    func scopes() async {
        let index = SearchIndex(tree: makeTree())
        let folders = await index.search(query: "d", scope: .folders)
        #expect(Set(folders.items.map(\.name)) == ["Documents", "drafts"])
        let allDirectories = folders.items.allSatisfy(\.isDirectory)
        #expect(allDirectories)

        let files = await index.search(query: "d", scope: .files)
        #expect(Set(files.items.map(\.name)) == ["Report Final.pdf", "report-old.PDF"])
        let anyDirectory = files.items.contains(where: \.isDirectory)
        #expect(!anyDirectory)
    }

    @Test("multiple tokens AND together")
    func multiToken() async {
        let index = SearchIndex(tree: makeTree())
        let results = await index.search(query: "report old", scope: .all)
        #expect(results.items.map(\.name) == ["report-old.PDF"])
    }

    @Test("decomposed (NFD) names match precomposed (NFC) queries")
    func unicodeNormalization() async {
        var tree = FileTree(rootName: "/")
        // "café" with a decomposed é, as APFS stores names typed elsewhere.
        tree.addNode(
            name: "cafe\u{0301}.txt", parent: FileTree.rootID, size: 10, isDirectory: false
        )
        tree.rollUpDirectorySizes()
        let index = SearchIndex(tree: tree)
        let results = await index.search(query: "Café", scope: .all)
        #expect(results.totalMatches == 1)
    }

    @Test("unlinked garbage nodes never match")
    func garbageExcluded() async {
        var tree = makeTree()
        tree.removeChild(named: "Documents", of: FileTree.rootID)
        let index = SearchIndex(tree: tree)
        let results = await index.search(query: "report", scope: .all)
        #expect(results.totalMatches == 0)
    }

    @Test("root node's path-name never matches; blank queries return nothing")
    func rootAndBlankExcluded() async {
        let index = SearchIndex(tree: makeTree())
        let root = await index.search(query: "Volumes", scope: .all)
        #expect(root.totalMatches == 0)
        let blank = await index.search(query: "   ", scope: .all)
        #expect(blank.totalMatches == 0)
        #expect(blank.items.isEmpty)
    }

    @Test("results cap at the display limit but report the true total")
    func resultLimit() async {
        var tree = FileTree(rootName: "/")
        for i in 0..<(SearchIndex.resultLimit + 50) {
            tree.addNode(
                name: "chunk-\(i).bin", parent: FileTree.rootID,
                size: Int64(i), isDirectory: false
            )
        }
        tree.rollUpDirectorySizes()
        let index = SearchIndex(tree: tree)
        let results = await index.search(query: "chunk", scope: .all)
        #expect(results.totalMatches == SearchIndex.resultLimit + 50)
        #expect(results.items.count == SearchIndex.resultLimit)
        // Largest first: the cap keeps the biggest matches.
        #expect(results.items.first?.size == Int64(SearchIndex.resultLimit + 49))
    }
}
