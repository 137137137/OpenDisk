import Foundation

struct FileTree: Sendable {
    typealias NodeID = Int32
    static let rootID: NodeID = 0
    static let noNode: NodeID = -1

    struct HardLinkKey: Hashable, Sendable {
        let device: UInt64
        let fileID: UInt64

        init(device: UInt64, fileID: UInt64) {
            self.device = device
            self.fileID = fileID
        }

        init(device: dev_t, fileID: UInt64) {
            self.init(device: UInt64(bitPattern: Int64(device)), fileID: fileID)
        }
    }

    private struct HardLink: Sendable {
        let key: HardLinkKey
        let allocatedSize: Int64
    }

    private struct Node: Sendable {
        var size: Int64
        var parent: NodeID
        var firstChild: NodeID
        var nextSibling: NodeID
        var isDirectory: Bool
    }

    private var nodes: [Node]
    private var names: [String]
    private var hardLinks: [NodeID: HardLink] = [:]

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

    @discardableResult
    mutating func addNode(
        name: String, parent: NodeID, size: Int64, isDirectory: Bool
    ) -> NodeID {
        let id = appendUnlinked(name: name, size: size, isDirectory: isDirectory)
        link(id, under: parent)
        return id
    }

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

    mutating func recordHardLink(_ id: NodeID, key: HardLinkKey, allocatedSize: Int64) {
        hardLinks[id] = HardLink(key: key, allocatedSize: allocatedSize)
    }

    func hardLinkKey(of id: NodeID) -> HardLinkKey? {
        hardLinks[id]?.key
    }

    var hardLinkKeys: Set<HardLinkKey> {
        Set(hardLinks.values.map(\.key))
    }

    var hardLinkedNodes: [(id: NodeID, key: HardLinkKey)] {
        hardLinks.map { ($0.key, $0.value.key) }
    }

    func reachableFiles(allocatedAtLeast minimum: Int64) -> [NodeID] {
        let reachable = reachabilityBitmap()
        var result: [NodeID] = []
        for index in nodes.indices where reachable[index] && !nodes[index].isDirectory {
            let size = nodes[index].size
            let id = NodeID(index)
            if size >= minimum || (size == 0 && (hardLinks[id]?.allocatedSize ?? 0) >= minimum) {
                result.append(id)
            }
        }
        return result
    }

    mutating func updateAllocatedSize(of id: NodeID, to size: Int64) {
        if let link = hardLinks[id] {
            hardLinks[id] = HardLink(key: link.key, allocatedSize: size)
        } else {
            nodes[Int(id)].size = size
        }
    }

    mutating func normalizeHardLinks() {
        guard !hardLinks.isEmpty else { return }
        let reachable = reachabilityBitmap()
        var counted = Set<HardLinkKey>()
        for id in hardLinks.keys.sorted() {
            guard reachable[Int(id)], let link = hardLinks[id] else {
                hardLinks[id] = nil
                continue
            }
            nodes[Int(id)].size = counted.insert(link.key).inserted ? link.allocatedSize : 0
        }
    }

    mutating func link(_ id: NodeID, under parent: NodeID) {
        nodes[Int(id)].parent = parent
        nodes[Int(id)].nextSibling = nodes[Int(parent)].firstChild
        nodes[Int(parent)].firstChild = id
    }

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

    func nodeID(forPath path: String, rootPath: String) -> NodeID? {
        if path == rootPath { return Self.rootID }
        let prefix = rootPath.directoryPrefix
        guard path.hasPrefix(prefix) else { return nil }
        return nodeID(atComponents: path.dropFirst(prefix.count).split(separator: "/"))
    }

    func childrenSortedForDisplay(of id: NodeID) -> [NodeID] {
        children(of: id).sorted {
            let (a, b) = (size(of: $0), size(of: $1))
            return a == b ? name(of: $0) < name(of: $1) : a > b
        }
    }

    var nodeCount: Int { nodes.count }

    func name(of id: NodeID) -> String { names[Int(id)] }
    func size(of id: NodeID) -> Int64 { nodes[Int(id)].size }
    func isDirectory(_ id: NodeID) -> Bool { nodes[Int(id)].isDirectory }
    func parent(of id: NodeID) -> NodeID { nodes[Int(id)].parent }

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

    func path(of id: NodeID) -> String {
        guard id != Self.rootID else { return names[0] }
        var components: [String] = []
        var remaining = nodes.count
        var current = id
        while current != Self.rootID && current != Self.noNode, remaining > 0 {
            remaining -= 1
            components.append(names[Int(current)])
            current = nodes[Int(current)].parent
        }
        return names[0].directoryPrefix + components.reversed().joined(separator: "/")
    }

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

    func reachabilityBitmap() -> [Bool] {
        var visited = [Bool](repeating: false, count: nodes.count)
        var stack: [NodeID] = [Self.rootID]
        visited[Int(Self.rootID)] = true
        while let current = stack.popLast() {
            var remaining = nodes.count
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

    mutating func rollUpDirectorySizes() {
        let count = nodes.count
        var visited = [Bool](repeating: false, count: count)

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

        for id in order.reversed() where id != Self.rootID {
            let parent = nodes[Int(id)].parent
            if parent != Self.noNode {
                nodes[Int(parent)].size += nodes[Int(id)].size
            }
        }
    }

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
                    mergeChildren(of: existing, from: other, otherDirectory: otherChild)
                } else {
                    removeChild(named: childName, of: directory)
                    adoptSubtree(from: other, otherNode: otherChild, under: directory)
                }
            } else {
                if child(of: directory, named: childName) == nil {
                    adoptSubtree(from: other, otherNode: otherChild, under: directory)
                }
            }
        }
    }

    func serializedData() -> Data {
        let count = nodes.count

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

        let linkedIDs = hardLinks.keys.sorted()
        append(UInt32(linkedIDs.count))
        appendArray(linkedIDs)
        appendArray(linkedIDs.map { hardLinks[$0]!.key.device })
        appendArray(linkedIDs.map { hardLinks[$0]!.key.fileID })
        appendArray(linkedIDs.map { hardLinks[$0]!.allocatedSize })
        return data
    }

    init?(serializedData data: Data) {
        let result: (nodes: [Node], names: [String], hardLinks: [NodeID: HardLink])? = data.withUnsafeBytes { raw in
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
            guard let linkCount32 = read(UInt32.self) else { return nil }
            let linkCount = Int(linkCount32)
            guard linkCount <= count,
                  let linkedIDs = readArray(NodeID.self, count: linkCount),
                  let devices = readArray(UInt64.self, count: linkCount),
                  let fileIDs = readArray(UInt64.self, count: linkCount),
                  let allocatedSizes = readArray(Int64.self, count: linkCount) else { return nil }
            var rebuiltHardLinks = [NodeID: HardLink](minimumCapacity: linkCount)
            for index in 0..<linkCount {
                let id = linkedIDs[index]
                guard id > Self.rootID, id < bound, !rebuiltNodes[Int(id)].isDirectory else { return nil }
                rebuiltHardLinks[id] = HardLink(
                    key: HardLinkKey(device: devices[index], fileID: fileIDs[index]),
                    allocatedSize: allocatedSizes[index]
                )
            }
            return (rebuiltNodes, rebuiltNames, rebuiltHardLinks)
        }
        guard let result else { return nil }
        nodes = result.nodes
        names = result.names
        hardLinks = result.hardLinks
    }

    private static let serializationMagic: UInt32 = 0x444D_5433

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
            if let link = other.hardLinks[source] {
                hardLinks[copy] = link
            }
            var child = other.nodes[Int(source)].firstChild
            while child != Self.noNode {
                stack.append((child, copy))
                child = other.nodes[Int(child)].nextSibling
            }
        }
    }
}
