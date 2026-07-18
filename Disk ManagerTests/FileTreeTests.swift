import Foundation
import Testing
@testable import Disk_Manager

@Suite("FileTree")
struct FileTreeTests {

    /// Builds:  /  ├─ Users/ ├─ a.txt(100)
    ///              │   ├─ alice/ ─ big.bin(4096)
    ///              │   └─ b.txt(50)
    private func makeSampleTree() -> FileTree {
        var tree = FileTree(rootName: "/")
        let users = tree.addNode(name: "Users", parent: FileTree.rootID, size: 0, isDirectory: true)
        let alice = tree.addNode(name: "alice", parent: users, size: 0, isDirectory: true)
        tree.addNode(name: "big.bin", parent: alice, size: 4_096, isDirectory: false)
        tree.addNode(name: "b.txt", parent: users, size: 50, isDirectory: false)
        tree.addNode(name: "a.txt", parent: FileTree.rootID, size: 100, isDirectory: false)
        return tree
    }

    @Test("rolls file sizes up into every ancestor directory")
    func rollUpAggregatesSizes() {
        var tree = makeSampleTree()
        tree.rollUpDirectorySizes()

        #expect(tree.size(of: FileTree.rootID) == 4_246)
        let users = tree.child(of: FileTree.rootID, named: "Users")!
        #expect(tree.size(of: users) == 4_146)
        let alice = tree.child(of: users, named: "alice")!
        #expect(tree.size(of: alice) == 4_096)
    }

    @Test("resolves nodes by path components and rebuilds paths")
    func pathResolutionRoundTrips() throws {
        let tree = makeSampleTree()
        let path = "Users/alice/big.bin"
        let node = tree.nodeID(atComponents: path.split(separator: "/"))
        let big = try #require(node)
        #expect(tree.name(of: big) == "big.bin")
        #expect(tree.path(of: big) == "/Users/alice/big.bin")
        #expect(tree.nodeID(atComponents: "Users/nobody".split(separator: "/")) == nil)
    }

    @Test("childCount tracks direct children only")
    func childCounts() {
        let tree = makeSampleTree()
        #expect(tree.childCount(of: FileTree.rootID) == 2)
        let users = tree.child(of: FileTree.rootID, named: "Users")!
        #expect(tree.childCount(of: users) == 2)
    }

    @Test("removeChild detaches a subtree from totals")
    func removeChildExcludesSubtree() {
        var tree = makeSampleTree()
        tree.removeChild(named: "Users", of: FileTree.rootID)
        tree.rollUpDirectorySizes()

        #expect(tree.size(of: FileTree.rootID) == 100)
        #expect(tree.child(of: FileTree.rootID, named: "Users") == nil)
        #expect(tree.childCount(of: FileTree.rootID) == 1)
    }

    @Test("merge combines same-named directories recursively")
    func mergeCombinesFirmlinkStyleTrees() {
        // System-style tree: /usr/bin/ls
        var system = FileTree(rootName: "/")
        let sysUsr = system.addNode(name: "usr", parent: FileTree.rootID, size: 0, isDirectory: true)
        let sysBin = system.addNode(name: "bin", parent: sysUsr, size: 0, isDirectory: true)
        system.addNode(name: "ls", parent: sysBin, size: 200, isDirectory: false)

        // Data-style tree: /usr/local/tool + /Users/alice/file
        var data = FileTree(rootName: "/")
        let dataUsr = data.addNode(name: "usr", parent: FileTree.rootID, size: 0, isDirectory: true)
        let local = data.addNode(name: "local", parent: dataUsr, size: 0, isDirectory: true)
        data.addNode(name: "tool", parent: local, size: 300, isDirectory: false)
        let users = data.addNode(name: "Users", parent: FileTree.rootID, size: 0, isDirectory: true)
        data.addNode(name: "file", parent: users, size: 700, isDirectory: false)

        system.merge(data)
        system.rollUpDirectorySizes()

        #expect(system.size(of: FileTree.rootID) == 1_200)
        // "usr" merged, not duplicated.
        #expect(system.children(of: FileTree.rootID).count == 2)
        let mergedUsr = system.child(of: FileTree.rootID, named: "usr")!
        #expect(system.size(of: mergedUsr) == 500)
        #expect(system.child(of: mergedUsr, named: "bin") != nil)
        #expect(system.child(of: mergedUsr, named: "local") != nil)
    }

    @Test("merge into a nested target grafts a volume in place")
    func mergeIntoNestedNode() {
        var base = FileTree(rootName: "/")
        let sys = base.addNode(name: "System", parent: FileTree.rootID, size: 0, isDirectory: true)
        let volumes = base.addNode(name: "Volumes", parent: sys, size: 0, isDirectory: true)
        let vm = base.addNode(name: "VM", parent: volumes, size: 0, isDirectory: true)

        var vmTree = FileTree(rootName: "/System/Volumes/VM")
        vmTree.addNode(name: "swapfile0", parent: FileTree.rootID, size: 1_024, isDirectory: false)

        base.merge(vmTree, into: vm)
        base.rollUpDirectorySizes()

        #expect(base.size(of: vm) == 1_024)
        #expect(base.size(of: FileTree.rootID) == 1_024)
    }

    @Test("unlinked and mutually-cyclic nodes neither hang nor count")
    func malformedLinksDoNotLoop() {
        var tree = FileTree(rootName: "/")
        let a = tree.appendUnlinked(name: "a", size: 0, isDirectory: true)
        let b = tree.appendUnlinked(name: "b", size: 0, isDirectory: true)
        let file = tree.appendUnlinked(name: "f", size: 10, isDirectory: false)
        tree.link(file, under: FileTree.rootID)
        // A mutual parent cycle detached from the root, as corrupt catalog
        // data could produce: roll-up must terminate and ignore it.
        tree.link(a, under: b)
        tree.link(b, under: a)
        tree.rollUpDirectorySizes()
        #expect(tree.size(of: FileTree.rootID) == 10)
    }
}
