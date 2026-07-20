import Foundation
import Testing
@testable import OpenDisk

@Suite("CatalogTreeBuilder")
struct CatalogTreeBuilderTests {

    private func entry(
        name: String, fileID: UInt64, parentID: UInt64,
        size: Int64 = 0, isDirectory: Bool = false, linkCount: UInt32 = 1
    ) -> CatalogEntry {
        CatalogEntry(
            name: name, fileID: fileID, parentID: parentID,
            size: size, isDirectory: isDirectory, linkCount: linkCount
        )
    }

    @Test("links children that stream before their parents")
    func outOfOrderEntriesLink() {
        var builder = CatalogTreeBuilder(rootName: "/")
        // Child arrives before its parent directory; parent IDs reference
        // the volume root (2) and directory 10.
        _ = builder.add(entry(name: "file.bin", fileID: 11, parentID: 10, size: 500))
        _ = builder.add(entry(name: "Folder", fileID: 10, parentID: 2, isDirectory: true))

        var tree = builder.buildTree()
        tree.rollUpDirectorySizes()

        let folder = tree.child(of: FileTree.rootID, named: "Folder")
        #expect(folder != nil)
        #expect(tree.size(of: FileTree.rootID) == 500)
        if let folder {
            #expect(tree.child(of: folder, named: "file.bin") != nil)
            #expect(tree.size(of: folder) == 500)
        }
    }

    @Test("attaches orphans to the root so their bytes still count")
    func orphansAttachToRoot() {
        var builder = CatalogTreeBuilder(rootName: "/")
        _ = builder.add(entry(name: "stranded.dat", fileID: 20, parentID: 999, size: 77))

        var tree = builder.buildTree()
        tree.rollUpDirectorySizes()

        #expect(tree.child(of: FileTree.rootID, named: "stranded.dat") != nil)
        #expect(tree.size(of: FileTree.rootID) == 77)
    }

    @Test("counts HFS-style duplicate hard-link records once")
    func hardLinkRecordsDeduplicate() {
        var builder = CatalogTreeBuilder(rootName: "/")
        let first = builder.add(entry(
            name: "link1", fileID: 30, parentID: 2, size: 1_000, linkCount: 2
        ))
        let second = builder.add(entry(
            name: "link2", fileID: 30, parentID: 2, size: 1_000, linkCount: 2
        ))
        #expect(first == 1_000)
        #expect(second == 0)

        var tree = builder.buildTree()
        tree.rollUpDirectorySizes()

        // Both names visible, bytes counted once.
        #expect(tree.childCount(of: FileTree.rootID) == 2)
        #expect(tree.size(of: FileTree.rootID) == 1_000)
    }

    @Test("partial snapshots exclude orphans until their ancestors stream in")
    func partialTreeExcludesOrphans() {
        var builder = CatalogTreeBuilder(rootName: "/")
        // A file whose parent directory has not streamed yet, plus one
        // directly under the volume root.
        _ = builder.add(entry(name: "file.bin", fileID: 11, parentID: 10, size: 500))
        _ = builder.add(entry(name: "rootfile.dat", fileID: 12, parentID: 2, size: 40))

        var early = builder.buildPartialTree()
        early.rollUpDirectorySizes()
        // The orphan must not flash at the top level of a live snapshot.
        #expect(early.child(of: FileTree.rootID, named: "file.bin") == nil)
        #expect(early.child(of: FileTree.rootID, named: "rootfile.dat") != nil)
        #expect(early.size(of: FileTree.rootID) == 40)

        // Its parent arrives: the next snapshot includes the whole chain.
        _ = builder.add(entry(name: "Folder", fileID: 10, parentID: 2, isDirectory: true))
        var later = builder.buildPartialTree()
        later.rollUpDirectorySizes()
        let folder = later.child(of: FileTree.rootID, named: "Folder")
        #expect(folder != nil)
        if let folder {
            #expect(later.child(of: folder, named: "file.bin") != nil)
            #expect(later.size(of: folder) == 500)
        }
        #expect(later.size(of: FileTree.rootID) == 540)

        // Snapshots never disturb the final build.
        var final = builder.buildTree()
        final.rollUpDirectorySizes()
        #expect(final.size(of: FileTree.rootID) == 540)
    }

    @Test("a file posing as a parent falls back to the root")
    func fileParentFallsBackToRoot() {
        var builder = CatalogTreeBuilder(rootName: "/")
        _ = builder.add(entry(name: "regular.txt", fileID: 40, parentID: 2, size: 10))
        _ = builder.add(entry(name: "child.txt", fileID: 41, parentID: 40, size: 20))

        var tree = builder.buildTree()
        tree.rollUpDirectorySizes()

        // child.txt cannot live under a file; it lands at the root.
        #expect(tree.childCount(of: FileTree.rootID) == 2)
        #expect(tree.size(of: FileTree.rootID) == 30)
    }
}
