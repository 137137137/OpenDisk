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
    /// array. Child counts are derived by walking the sibling chain — the
    /// few places that need them touch at most ~100 visible rows.
    private struct Node: Sendable {
        var size: Int64
        var parent: NodeID
        var firstChild: NodeID
        var nextSibling: NodeID
        var isDirectory: Bool
    }

    private var nodes: [Node]
    private var names: [String]

    // MARK: - Construction

    /// Creates a tree containing only a root directory named `rootName`.
    init(rootName: String) {
        nodes = [Node(
            size: 0, parent: Self.noNode, firstChild: Self.noNode,
            nextSibling: Self.noNode, isDirectory: true
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
            nextSibling: Self.noNode, isDirectory: isDirectory
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
    }

    /// Unlinks every child of `parent`, leaving their subtrees as
    /// unreachable garbage nodes (excluded from totals and hit-testing).
    /// Used by incremental updates that re-list a changed directory and
    /// re-link the survivors.
    mutating func removeAllChildren(of parent: NodeID) {
        var current = nodes[Int(parent)].firstChild
        while current != Self.noNode {
            let next = nodes[Int(current)].nextSibling
            nodes[Int(current)].parent = Self.noNode
            nodes[Int(current)].nextSibling = Self.noNode
            current = next
        }
        nodes[Int(parent)].firstChild = Self.noNode
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
                nodes[Int(current)].parent = Self.noNode
                nodes[Int(current)].nextSibling = Self.noNode
                return current
            }
            previous = current
            current = nodes[Int(current)].nextSibling
        }
        return nil
    }

    /// Resolves a node from an absolute path against the scan root the
    /// tree was built for. Every layer that maps paths back to nodes
    /// (navigation, incremental updates) shares this one implementation.
    func nodeID(forPath path: String, rootPath: String) -> NodeID? {
        if path == rootPath { return Self.rootID }
        let prefix = rootPath.directoryPrefix
        guard path.hasPrefix(prefix) else { return nil }
        return nodeID(atComponents: path.dropFirst(prefix.count).split(separator: "/"))
    }

    /// Children ordered the one way the app displays them — size
    /// descending, name ascending on ties so successive live snapshots
    /// never shuffle equal-sized rows. The list and the chart both use
    /// this, keeping their orders identical by construction.
    func childrenSortedForDisplay(of id: NodeID) -> [NodeID] {
        children(of: id).sorted {
            let (a, b) = (size(of: $0), size(of: $1))
            return a == b ? name(of: $0) < name(of: $1) : a > b
        }
    }

    // MARK: - Queries

    var nodeCount: Int { nodes.count }

    func name(of id: NodeID) -> String { names[Int(id)] }
    func size(of id: NodeID) -> Int64 { nodes[Int(id)].size }
    func isDirectory(_ id: NodeID) -> Bool { nodes[Int(id)].isDirectory }
    func parent(of id: NodeID) -> NodeID { nodes[Int(id)].parent }

    /// Number of direct children (files and directories).
    ///
    /// Sibling walks here and below are bounded by the node count: a
    /// corrupted cache file could contain a sibling-chain cycle that range
    /// validation alone cannot catch, and an unbounded walk would hang the
    /// app forever (`rollUpDirectorySizes` is already guarded; these were
    /// not).
    func childCount(of id: NodeID) -> Int {
        var count = 0
        var remaining = nodes.count
        var current = nodes[Int(id)].firstChild
        while current != Self.noNode, remaining > 0 {
            remaining -= 1
            count += 1
            current = nodes[Int(current)].nextSibling
        }
        return count
    }

    func children(of id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var remaining = nodes.count
        var current = nodes[Int(id)].firstChild
        while current != Self.noNode, remaining > 0 {
            remaining -= 1
            result.append(current)
            current = nodes[Int(current)].nextSibling
        }
        return result
    }

    func child(of id: NodeID, named name: String) -> NodeID? {
        var remaining = nodes.count
        var current = nodes[Int(id)].firstChild
        while current != Self.noNode, remaining > 0 {
            remaining -= 1
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
        var remaining = nodes.count   // bound: see childCount(of:)
        var current = id
        while current != Self.rootID && current != Self.noNode, remaining > 0 {
            remaining -= 1
            components.append(names[Int(current)])
            current = nodes[Int(current)].parent
        }
        return names[0].directoryPrefix + components.reversed().joined(separator: "/")
    }

    /// Per-node (size, isDirectory) snapshot as flat arrays for consumers
    /// that process millions of nodes with pointer access (the search
    /// index): reading through these avoids a method call — and its ARC
    /// traffic, ruinous in unoptimized builds — per node.
    func sizeAndKindArrays() -> (sizes: [Int64], directoryFlags: [Bool]) {
        let count = nodes.count
        var sizes = [Int64](repeating: 0, count: count)
        var flags = [Bool](repeating: false, count: count)
        nodes.withUnsafeBufferPointer { source in
            sizes.withUnsafeMutableBufferPointer { sizesOut in
                flags.withUnsafeMutableBufferPointer { flagsOut in
                    for index in 0..<count {
                        sizesOut[index] = source[index].size
                        flagsOut[index] = source[index].isDirectory
                    }
                }
            }
        }
        return (sizes, flags)
    }

    /// Bitmap of nodes reachable from the root. Incremental updates and
    /// merges leave unlinked garbage nodes in the arrays; consumers that
    /// enumerate nodes by index (the search index) use this to skip them.
    func reachabilityBitmap() -> [Bool] {
        var visited = [Bool](repeating: false, count: nodes.count)
        var stack: [NodeID] = [Self.rootID]
        visited[Int(Self.rootID)] = true
        while let current = stack.popLast() {
            var remaining = nodes.count   // bound: see childCount(of:)
            var child = nodes[Int(current)].firstChild
            while child != Self.noNode, remaining > 0 {
                remaining -= 1
                if !visited[Int(child)] {
                    visited[Int(child)] = true
                    stack.append(child)
                }
                child = nodes[Int(child)].nextSibling
            }
        }
        return visited
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
                // Non-directory collisions keep the existing node —
                // duplicate sibling names would break path-keyed identity.
                if child(of: directory, named: childName) == nil {
                    adoptSubtree(from: other, otherNode: otherChild, under: directory)
                }
            }
        }
    }

    // MARK: - Serialization

    /// Compact binary form for the on-disk scan cache: fixed-width field
    /// arrays plus one UTF-8 name blob. Encoding a multi-million-node
    /// tree is one pass over the nodes plus a handful of memcpys.
    func serializedData() -> Data {
        let count = nodes.count

        // One pass fills every per-node field array (no map temporaries).
        var sizes = [Int64](repeating: 0, count: count)
        var parents = [NodeID](repeating: 0, count: count)
        var firstChildren = [NodeID](repeating: 0, count: count)
        var nextSiblings = [NodeID](repeating: 0, count: count)
        var directoryFlags = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            let node = nodes[index]
            sizes[index] = node.size
            parents[index] = node.parent
            firstChildren[index] = node.firstChild
            nextSiblings[index] = node.nextSibling
            directoryFlags[index] = node.isDirectory ? 1 : 0
        }

        // Names: first pass records lengths and the blob's total size so
        // the blob is appended into preallocated storage.
        var nameLengths = [UInt32](repeating: 0, count: count)
        var blobLength = 0
        for index in 0..<count {
            let length = names[index].utf8.count
            nameLengths[index] = UInt32(length)
            blobLength += length
        }

        var data = Data(capacity: count * 29 + blobLength + 16)
        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        func appendArray<T>(_ values: [T]) {
            values.withUnsafeBufferPointer {
                data.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self))
            }
        }

        append(Self.serializationMagic)
        append(UInt32(count))
        appendArray(sizes)
        appendArray(parents)
        appendArray(firstChildren)
        appendArray(nextSiblings)
        appendArray(directoryFlags)
        appendArray(nameLengths)
        append(UInt32(blobLength))
        for name in names {
            data.append(contentsOf: name.utf8)
        }
        return data
    }

    /// Rebuilds a tree from `serializedData()` output; nil when the blob
    /// is malformed or from a different format version. Accepts slices
    /// (offsets are relative to `data.startIndex`), so callers can pass a
    /// no-copy view into a larger mapped file.
    init?(serializedData data: Data) {
        let result: (nodes: [Node], names: [String])? = data.withUnsafeBytes { raw in
            var offset = 0
            func read<T>(_ type: T.Type) -> T? {
                let size = MemoryLayout<T>.size
                guard offset + size <= raw.count else { return nil }
                defer { offset += size }
                return raw.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
            func readArray<T>(_ type: T.Type, count: Int) -> [T]? {
                let size = MemoryLayout<T>.stride * count
                guard offset + size <= raw.count else { return nil }
                defer { offset += size }
                return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                    raw.copyBytes(
                        to: UnsafeMutableRawBufferPointer(buffer),
                        from: offset..<(offset + size)
                    )
                    initialized = count
                }
            }

            guard read(UInt32.self) == Self.serializationMagic,
                  let count32 = read(UInt32.self), count32 > 0 else { return nil }
            let count = Int(count32)
            guard let sizes = readArray(Int64.self, count: count),
                  let parents = readArray(NodeID.self, count: count),
                  let firstChildren = readArray(NodeID.self, count: count),
                  let nextSiblings = readArray(NodeID.self, count: count),
                  let directoryFlags = readArray(UInt8.self, count: count),
                  let nameLengths = readArray(UInt32.self, count: count),
                  let blobLength = read(UInt32.self),
                  offset + Int(blobLength) <= raw.count else { return nil }

            var rebuiltNames = [String]()
            rebuiltNames.reserveCapacity(count)
            for length in nameLengths {
                let end = offset + Int(length)
                guard end <= raw.count else { return nil }
                rebuiltNames.append(String(
                    decoding: UnsafeRawBufferPointer(rebasing: raw[offset..<end]),
                    as: UTF8.self
                ))
                offset = end
            }

            var rebuiltNodes = [Node]()
            rebuiltNodes.reserveCapacity(count)
            let bound = NodeID(count)
            for index in 0..<count {
                // Malformed links would corrupt traversal; validate range —
                // both ends, or a bit-rotted negative index (anything other
                // than the -1 sentinel) traps on the first array access and
                // turns a stale cache file into a crash loop.
                guard parents[index] >= Self.noNode, parents[index] < bound,
                      firstChildren[index] >= Self.noNode, firstChildren[index] < bound,
                      nextSiblings[index] >= Self.noNode, nextSiblings[index] < bound
                else { return nil }
                rebuiltNodes.append(Node(
                    size: sizes[index],
                    parent: parents[index],
                    firstChild: firstChildren[index],
                    nextSibling: nextSiblings[index],
                    isDirectory: directoryFlags[index] != 0
                ))
            }
            return (rebuiltNodes, rebuiltNames)
        }
        guard let result else { return nil }
        nodes = result.nodes
        names = result.names
    }

    private static let serializationMagic: UInt32 = 0x444D_5432 // "DMT2"

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
