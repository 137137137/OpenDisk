import Foundation

/// Compact, index-linked snapshot of a scanned file hierarchy.
///
/// Nodes are stored in flat arrays and linked by `Int32` indices instead of
/// object references, and no full paths are stored — a node's path is
/// derived from its parent chain on demand. This keeps a multi-million-file
/// scan to tens of bytes per entry (roughly an order of magnitude less
/// memory than a boxed node tree with per-node path strings) with no ARC
/// traffic while scanning.
///
/// The root is always node 0. Value semantics: `FileTree` is `Sendable` and
/// can be handed from scan workers to the main actor wholesale.
struct FileTree: Sendable {

    typealias NodeID = Int32
    static let rootID: NodeID = 0
    static let noNode: NodeID = -1

    /// Per-node fixed-size storage; names live in the parallel `names`
    /// array. 32 bytes per node.
    private struct Node: Sendable {
        var size: Int64
        var parent: NodeID
        var firstChild: NodeID
        var nextSibling: NodeID
        var childCount: Int32
        var isDirectory: Bool
    }

    private var nodes: [Node]
    private var names: [String]

    // MARK: - Construction

    /// Creates a tree containing only a root directory named `rootName`.
    init(rootName: String) {
        nodes = [Node(
            size: 0, parent: Self.noNode, firstChild: Self.noNode,
            nextSibling: Self.noNode, childCount: 0, isDirectory: true
        )]
        names = [rootName]
    }

    mutating func reserveCapacity(_ count: Int) {
        nodes.reserveCapacity(count)
        names.reserveCapacity(count)
    }

    /// Appends a node and links it under `parent`.
    @discardableResult
    mutating func addNode(
        name: String, parent: NodeID, size: Int64, isDirectory: Bool
    ) -> NodeID {
        let id = appendUnlinked(name: name, size: size, isDirectory: isDirectory)
        link(id, under: parent)
        return id
    }

    /// Appends a node without linking it anywhere. Used by builders that
    /// discover parents after children; every appended node must later be
    /// linked exactly once or it is simply excluded from totals.
    mutating func appendUnlinked(
        name: String, size: Int64, isDirectory: Bool
    ) -> NodeID {
        let id = NodeID(nodes.count)
        nodes.append(Node(
            size: size, parent: Self.noNode, firstChild: Self.noNode,
            nextSibling: Self.noNode, childCount: 0, isDirectory: isDirectory
        ))
        names.append(name)
        return id
    }

    /// Links a previously unlinked node under `parent` (O(1): the child is
    /// prepended to the parent's child list).
    mutating func link(_ id: NodeID, under parent: NodeID) {
        nodes[Int(id)].parent = parent
        nodes[Int(id)].nextSibling = nodes[Int(parent)].firstChild
        nodes[Int(parent)].firstChild = id
        nodes[Int(parent)].childCount += 1
    }

    /// Unlinks the child named `name` from `parent`, excluding its whole
    /// subtree from totals. Returns the unlinked node, if found.
    @discardableResult
    mutating func removeChild(named name: String, of parent: NodeID) -> NodeID? {
        var previous = Self.noNode
        var current = nodes[Int(parent)].firstChild
        while current != Self.noNode {
            if names[Int(current)] == name {
                if previous == Self.noNode {
                    nodes[Int(parent)].firstChild = nodes[Int(current)].nextSibling
                } else {
                    nodes[Int(previous)].nextSibling = nodes[Int(current)].nextSibling
                }
                nodes[Int(parent)].childCount -= 1
                nodes[Int(current)].parent = Self.noNode
                nodes[Int(current)].nextSibling = Self.noNode
                return current
            }
            previous = current
            current = nodes[Int(current)].nextSibling
        }
        return nil
    }

    // MARK: - Queries

    var nodeCount: Int { nodes.count }

    func name(of id: NodeID) -> String { names[Int(id)] }
    func size(of id: NodeID) -> Int64 { nodes[Int(id)].size }
    func isDirectory(_ id: NodeID) -> Bool { nodes[Int(id)].isDirectory }
    func parent(of id: NodeID) -> NodeID { nodes[Int(id)].parent }

    /// Number of direct children (files and directories).
    func childCount(of id: NodeID) -> Int { Int(nodes[Int(id)].childCount) }

    func children(of id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        result.reserveCapacity(childCount(of: id))
        var current = nodes[Int(id)].firstChild
        while current != Self.noNode {
            result.append(current)
            current = nodes[Int(current)].nextSibling
        }
        return result
    }

    func child(of id: NodeID, named name: String) -> NodeID? {
        var current = nodes[Int(id)].firstChild
        while current != Self.noNode {
            if names[Int(current)] == name { return current }
            current = nodes[Int(current)].nextSibling
        }
        return nil
    }

    /// Resolves a node by walking name components from the root.
    func nodeID<S: Sequence>(atComponents components: S) -> NodeID?
    where S.Element == Substring {
        var current = Self.rootID
        for component in components where !component.isEmpty {
            guard let next = child(of: current, named: String(component)) else {
                return nil
            }
            current = next
        }
        return current
    }

    /// Builds the absolute path of a node by walking its parent chain,
    /// treating the root's name as the path prefix ("/" is not doubled).
    func path(of id: NodeID) -> String {
        guard id != Self.rootID else { return names[0] }
        var components: [String] = []
        var current = id
        while current != Self.rootID && current != Self.noNode {
            components.append(names[Int(current)])
            current = nodes[Int(current)].parent
        }
        let rootName = names[0]
        let prefix = rootName.hasSuffix("/") ? rootName : rootName + "/"
        return prefix + components.reversed().joined(separator: "/")
    }

    // MARK: - Finalization

    /// Rolls file sizes up into every ancestor directory.
    ///
    /// Directory nodes are expected to carry size 0 before this runs; after
    /// it, every directory's size is the sum of its reachable subtree.
    /// Iterative (explicit stack) so arbitrarily deep trees cannot overflow
    /// the thread stack, and guarded by a visited bitmap so malformed
    /// parent links (cycles) cannot loop forever.
    mutating func rollUpDirectorySizes() {
        let count = nodes.count
        var visited = [Bool](repeating: false, count: count)

        // Pre-order walk recorded into an array...
        var order = [NodeID]()
        order.reserveCapacity(count)
        var stack: [NodeID] = [Self.rootID]
        visited[Int(Self.rootID)] = true
        while let current = stack.popLast() {
            order.append(current)
            var child = nodes[Int(current)].firstChild
            while child != Self.noNode {
                if !visited[Int(child)] {
                    visited[Int(child)] = true
                    stack.append(child)
                }
                child = nodes[Int(child)].nextSibling
            }
        }

        // ...then replayed in reverse: children always precede their parent,
        // so a single pass accumulates sizes bottom-up.
        for id in order.reversed() where id != Self.rootID {
            let parent = nodes[Int(id)].parent
            if parent != Self.noNode {
                nodes[Int(parent)].size += nodes[Int(id)].size
            }
        }
    }

    // MARK: - Merging

    /// Merges another tree's hierarchy into `directory` of this one.
    ///
    /// For every child of `other`'s root: if `directory` has a same-named
    /// subdirectory, the two directories' contents are merged recursively;
    /// otherwise the whole subtree is copied over.
    ///
    /// This is how the composite "/" scan combines the System and Data
    /// volumes: firmlink merge points (like `/usr` holding the system
    /// `/usr` plus the Data volume's `usr/local`) resolve by name, exactly
    /// mirroring how macOS composes the two volumes.
    ///
    /// Call before `rollUpDirectorySizes()` — sizes are rolled up once, on
    /// the fully merged tree.
    mutating func merge(_ other: FileTree, into directory: NodeID = FileTree.rootID) {
        mergeChildren(of: directory, from: other, otherDirectory: Self.rootID)
    }

    private mutating func mergeChildren(
        of directory: NodeID, from other: FileTree, otherDirectory: NodeID
    ) {
        for otherChild in other.children(of: otherDirectory) {
            let childName = other.name(of: otherChild)
            if other.isDirectory(otherChild), let existing = child(of: directory, named: childName) {
                if isDirectory(existing) {
                    // Recursion depth is bounded by the depth of colliding
                    // directories (firmlink merge points), a handful of levels.
                    mergeChildren(of: existing, from: other, otherDirectory: otherChild)
                } else {
                    // A same-named non-directory (e.g. a firmlink stub the
                    // filesystem reported oddly) loses to the real directory.
                    removeChild(named: childName, of: directory)
                    adoptSubtree(from: other, otherNode: otherChild, under: directory)
                }
            } else {
                adoptSubtree(from: other, otherNode: otherChild, under: directory)
            }
        }
    }

    /// Copies a whole subtree from another tree under `parent`.
    /// Iterative to survive arbitrarily deep hierarchies.
    mutating func adoptSubtree(
        from other: FileTree, otherNode: FileTree.NodeID, under parent: NodeID
    ) {
        var stack: [(source: FileTree.NodeID, newParent: NodeID)] = [(otherNode, parent)]
        while let (source, newParent) = stack.popLast() {
            let copy = addNode(
                name: other.name(of: source),
                parent: newParent,
                size: other.isDirectory(source) ? 0 : other.size(of: source),
                isDirectory: other.isDirectory(source)
            )
            var child = other.nodes[Int(source)].firstChild
            while child != Self.noNode {
                stack.append((child, copy))
                child = other.nodes[Int(child)].nextSibling
            }
        }
    }
}
