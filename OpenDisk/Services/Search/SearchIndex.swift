import Foundation

/// Which kinds of entries a search matches.
enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case folders = "Folders"
    case files = "Files"
    var id: String { rawValue }
}

/// Immutable name-search index over one `FileTree` snapshot.
///
/// Every node's name is case-folded and canonically composed (so an NFC
/// query like "café" matches APFS's decomposed on-disk form), then packed
/// into one contiguous NUL-separated UTF-8 blob with an offsets array.
///
/// A query is answered by sweeping the whole blob with `memmem` — the
/// byte scanning happens inside libc, so throughput is identical in Debug
/// and Release builds (a per-name Swift loop was ~1700x slower at -Onone,
/// seconds per keystroke on a 5M-node tree). Names cannot contain NUL, so
/// a match can never straddle two names, and Swift code runs only per
/// *hit*, not per byte. Chunks of the name range sweep in parallel.
///
/// Value semantics: `Sendable`, safe to hand to any task. The tree it
/// wraps is retained so results can materialize paths and sizes.
struct SearchIndex: Sendable {

    /// Matches are unbounded (a short query can hit millions of names);
    /// only the largest `resultLimit` are materialized for display.
    static let resultLimit = 500

    let tree: FileTree
    /// Folded names back to back, each terminated by a 0x00 separator.
    private let blob: [UInt8]
    /// `nodeCount + 1` entries; name `i` occupies
    /// `blob[offsets[i] ..< offsets[i + 1] - 1]` (the -1 skips its NUL).
    private let offsets: [Int]
    /// Nodes reachable from the root; garbage left by incremental
    /// unlinking never appears in results.
    private let reachable: [Bool]
    /// Flat per-node copies of size and kind. The sweep reads these
    /// through raw pointers instead of calling tree accessors per hit —
    /// a method call per hit is ARC-bound and ruinously slow in Debug
    /// builds when a one-letter query hits millions of names.
    private let sizes: [Int64]
    private let directoryFlags: [Bool]

    // MARK: - Construction

    /// Builds the index. Runs the name folding in parallel chunks with a
    /// byte-level ASCII fast path (Foundation folding only for the rare
    /// non-ASCII name) — a few hundred ms for a multi-million-node tree,
    /// in Debug builds too. Still: call off the main actor.
    init(tree: FileTree) {
        let count = tree.nodeCount
        let chunkSize = 131_072
        let chunkCount = max(1, (count + chunkSize - 1) / chunkSize)

        // Each chunk folds its share of names into a private buffer and
        // records per-name lengths (name bytes + NUL); the buffers are
        // then stitched with bulk copies.
        var chunkBlobs = [[UInt8]](repeating: [], count: chunkCount)
        var chunkLengths = [[Int32]](repeating: [], count: chunkCount)
        chunkBlobs.withUnsafeMutableBufferPointer { blobsOut in
            chunkLengths.withUnsafeMutableBufferPointer { lengthsOut in
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
                    blobsOut[chunk] = local
                    lengthsOut[chunk] = lengths
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

    /// The one normalization applied to indexed names and queries alike:
    /// case folding plus canonical composition, so byte-level matching is
    /// correct for mixed-case and decomposed-Unicode names.
    private static func fold(_ s: String) -> String {
        s.lowercased().precomposedStringWithCanonicalMapping
    }

    /// Appends `fold(name)`'s UTF-8 to `out`. Pure-ASCII names (the vast
    /// majority) are lowercased byte-by-byte with no Foundation round
    /// trip; anything else takes the full folding path.
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

    // MARK: - Searching

    struct Results: Sendable {
        /// The largest `resultLimit` matches, size-descending.
        let items: [FolderItem]
        /// Total match count before the display cap.
        let totalMatches: Int

        static let empty = Results(items: [], totalMatches: 0)
    }

    private struct ChunkResult {
        let entries: [MinSizeHeap.Entry]
        let matched: Int
    }

    /// Finds every reachable node whose name contains all whitespace-
    /// separated tokens of `query` (case- and composition-insensitive),
    /// returning the largest matches first. Cancelling the surrounding
    /// task aborts the sweep within milliseconds.
    func search(query: String, scope: SearchScope) async -> Results {
        var tokens = Self.fold(query)
            .split(whereSeparator: \.isWhitespace)
            .map { Array($0.utf8) }
        guard !tokens.isEmpty, tree.nodeCount > 1 else { return .empty }
        // The longest token drives the C sweep (fewest hits); the rest
        // are verified per hit within the one matched name.
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

        // Size-descending, name ascending on ties — the app's one display
        // order, so search reads like the rest of the UI.
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

    /// Sweeps one contiguous range of names with `memmem`. Byte scanning
    /// stays inside libc; Swift work is proportional to the number of
    /// hits. Returns nil when cancelled mid-sweep (partial data useless).
    /// The root (node 0) never matches — its "name" is the scan root's
    /// path, not a real entry.
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
                        // Inline heap-admission threshold: once the heap
                        // is full, the common case (a match too small to
                        // display) is rejected with one integer compare
                        // instead of a method call.
                        var heapFull = false
                        var heapMin = Int64.min

                        while cursor < end {
                            guard let found = memmem(
                                base + cursor, end - cursor, needle, needleLength
                            ) else { break }
                            let position = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                            // Hits arrive in order; roll the name index
                            // forward to the one containing this hit.
                            while offset[nameIndex + 1] <= position { nameIndex += 1 }
                            // One hit per name: resume after this name.
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

/// Fixed-capacity min-heap keeping the K largest (size, node) pairs seen.
/// Comparisons touch only `Int64` sizes — no name materialization — so
/// feeding it millions of matches stays cheap.
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
