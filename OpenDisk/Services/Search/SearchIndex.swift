import Foundation

enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case folders = "Folders"
    case files = "Files"
    var id: String { rawValue }
}

struct SearchIndex: Sendable {

    static let resultLimit = 500

    let tree: FileTree
    private let blob: [UInt8]
    private let offsets: [Int]
    private let reachable: [Bool]
    private let sizes: [Int64]
    private let directoryFlags: [Bool]

    private struct UncheckedSendableBuffer<Element>: @unchecked Sendable {
        let base: UnsafeMutableBufferPointer<Element>
    }

    init(tree: FileTree) {
        let count = tree.nodeCount
        let chunkSize = 131_072
        let chunkCount = max(1, (count + chunkSize - 1) / chunkSize)

        var chunkBlobs = [[UInt8]](repeating: [], count: chunkCount)
        var chunkLengths = [[Int32]](repeating: [], count: chunkCount)
        chunkBlobs.withUnsafeMutableBufferPointer { blobsOut in
            chunkLengths.withUnsafeMutableBufferPointer { lengthsOut in
                let blobs = UncheckedSendableBuffer<[UInt8]>(base: blobsOut)
                let allLengths = UncheckedSendableBuffer<[Int32]>(base: lengthsOut)
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                    let low = chunk * chunkSize
                    let high = min(count, low + chunkSize)
                    var local = [UInt8]()
                    local.reserveCapacity((high - low) * 24)
                    var lengths = [Int32]()
                    lengths.reserveCapacity(high - low)
                    for id in low..<high {
                        let start = local.count
                        Self.appendFolded(tree.name(of: FileTree.NodeID(id)), to: &local)
                        local.append(0)
                        lengths.append(Int32(local.count - start))
                    }
                    blobs.base[chunk] = local
                    allLengths.base[chunk] = lengths
                }
            }
        }

        let totalBytes = chunkBlobs.reduce(0) { $0 + $1.count }
        var stitched = [UInt8]()
        stitched.reserveCapacity(totalBytes)
        for chunkBlob in chunkBlobs {
            stitched.append(contentsOf: chunkBlob)
        }

        var offsets = [Int](repeating: 0, count: count + 1)
        var running = 0
        var nameIndex = 0
        for lengths in chunkLengths {
            for length in lengths {
                offsets[nameIndex] = running
                running += Int(length)
                nameIndex += 1
            }
        }
        offsets[count] = running

        self.tree = tree
        self.blob = stitched
        self.offsets = offsets
        self.reachable = tree.reachabilityBitmap()
        (self.sizes, self.directoryFlags) = tree.sizeAndKindArrays()
    }

    private static func fold(_ s: String) -> String {
        s.lowercased().precomposedStringWithCanonicalMapping
    }

    private static func appendFolded(_ name: String, to out: inout [UInt8]) {
        var name = name
        let handled = name.withUTF8 { bytes -> Bool in
            var hasUpper = false
            for byte in bytes {
                if byte >= 0x80 { return false }
                if byte >= 0x41 && byte <= 0x5A { hasUpper = true }
            }
            if hasUpper {
                for byte in bytes {
                    out.append(byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte)
                }
            } else {
                out.append(contentsOf: bytes)
            }
            return true
        }
        if !handled {
            out.append(contentsOf: fold(name).utf8)
        }
    }

    struct Results: Sendable {
        let items: [FolderItem]
        let totalMatches: Int

        static let empty = Results(items: [], totalMatches: 0)
    }

    private struct ChunkResult {
        let entries: [MinSizeHeap.Entry]
        let matched: Int
    }

    func search(query: String, scope: SearchScope) async -> Results {
        var tokens = Self.fold(query)
            .split(whereSeparator: \.isWhitespace)
            .map { Array($0.utf8) }
        guard !tokens.isEmpty, tree.nodeCount > 1 else { return .empty }
        tokens.sort { $0.count > $1.count }
        let primary = tokens[0]
        let secondary = Array(tokens.dropFirst())

        let count = tree.nodeCount
        let chunkSize = 262_144
        let chunkCount = (count + chunkSize - 1) / chunkSize

        let (heap, total) = await withTaskGroup(of: ChunkResult?.self) { group in
            for chunk in 0..<chunkCount {
                let names = (chunk * chunkSize)..<min(count, (chunk + 1) * chunkSize)
                group.addTask {
                    sweep(names: names, primary: primary, secondary: secondary, scope: scope)
                }
            }
            var heap = MinSizeHeap(capacity: Self.resultLimit)
            var total = 0
            for await chunkResult in group {
                guard let chunkResult else { continue }
                total += chunkResult.matched
                for entry in chunkResult.entries {
                    heap.offer(size: entry.size, id: entry.id)
                }
            }
            return (heap, total)
        }
        if Task.isCancelled { return .empty }

        let ranked = heap.entries.sorted {
            $0.size == $1.size
                ? tree.name(of: $0.id) < tree.name(of: $1.id)
                : $0.size > $1.size
        }
        let items = ranked.map { entry in
            FolderItem(
                name: tree.name(of: entry.id),
                path: tree.path(of: entry.id),
                size: entry.size,
                isDirectory: tree.isDirectory(entry.id),
                itemCount: tree.isDirectory(entry.id) ? tree.childCount(of: entry.id) : 0
            )
        }
        return Results(items: items, totalMatches: total)
    }

    // memmem, not a Swift byte loop: the loop was ~1700x slower at -Onone (seconds per keystroke on 5M nodes).
    private func sweep(
        names: Range<Int>, primary: [UInt8], secondary: [[UInt8]], scope: SearchScope
    ) -> ChunkResult? {
        var heap = MinSizeHeap(capacity: Self.resultLimit)
        var matched = 0
        var cancelled = false

        blob.withUnsafeBufferPointer { blobBuffer in
            offsets.withUnsafeBufferPointer { offset in
                reachable.withUnsafeBufferPointer { reach in
                    sizes.withUnsafeBufferPointer { size in
                        directoryFlags.withUnsafeBufferPointer { isDir in
                            primary.withUnsafeBufferPointer { needleBuffer in
                        guard let base = blobBuffer.baseAddress,
                              let needle = needleBuffer.baseAddress else { return }
                        let needleLength = needleBuffer.count
                        var nameIndex = names.lowerBound
                        var cursor = offset[names.lowerBound]
                        let end = offset[names.upperBound]
                        var hits = 0
                        var heapFull = false
                        var heapMin = Int64.min

                        while cursor < end {
                            guard let found = memmem(
                                base + cursor, end - cursor, needle, needleLength
                            ) else { break }
                            let position = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                            while offset[nameIndex + 1] <= position { nameIndex += 1 }
                            cursor = offset[nameIndex + 1]

                            hits += 1
                            if hits & 0x0FFF == 0 && Task.isCancelled {
                                cancelled = true
                                return
                            }

                            let index = nameIndex
                            if index == 0 || !reach[index] { continue }
                            switch scope {
                            case .all:
                                break
                            case .folders:
                                if !isDir[index] { continue }
                            case .files:
                                if isDir[index] { continue }
                            }
                            if !secondary.isEmpty {
                                let start = offset[index]
                                let length = offset[index + 1] - 1 - start
                                var matchesAll = true
                                for token in secondary {
                                    if token.count > length || memmem(
                                        base + start, length, token, token.count
                                    ) == nil {
                                        matchesAll = false
                                        break
                                    }
                                }
                                if !matchesAll { continue }
                            }
                            matched += 1
                            let nodeSize = size[index]
                            if heapFull && nodeSize <= heapMin { continue }
                            heap.offer(size: nodeSize, id: FileTree.NodeID(index))
                            if heap.entries.count == Self.resultLimit {
                                heapFull = true
                                heapMin = heap.entries[0].size
                            }
                        }
                            }
                        }
                    }
                }
            }
        }
        return cancelled ? nil : ChunkResult(entries: heap.entries, matched: matched)
    }
}

private struct MinSizeHeap {
    struct Entry {
        let size: Int64
        let id: FileTree.NodeID
    }

    private(set) var entries: [Entry] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    mutating func offer(size: Int64, id: FileTree.NodeID) {
        if entries.count < capacity {
            entries.append(Entry(size: size, id: id))
            siftUp(from: entries.count - 1)
        } else if size > entries[0].size {
            entries[0] = Entry(size: size, id: id)
            siftDown(from: 0)
        }
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard entries[child].size < entries[parent].size else { break }
            entries.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < entries.count && entries[left].size < entries[smallest].size {
                smallest = left
            }
            if right < entries.count && entries[right].size < entries[smallest].size {
                smallest = right
            }
            guard smallest != parent else { return }
            entries.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
