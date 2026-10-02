import Foundation

/// Compact, size-pruned view of a scan. Shared by export, history, and the AI agent;
/// it never contains anything but paths and sizes.
struct ScanDigest: Codable, Sendable, Equatable {
    var rootPath: String
    var date: Date
    var totalBytes: Int64
    var volumeCapacity: Int64?
    var volumeAvailable: Int64?
    /// Pre-order, largest first.
    var entries: [Entry]

    struct Entry: Codable, Sendable, Equatable {
        var path: String
        var size: Int64
        var isDir: Bool
        var depth: Int
        /// Children below the size threshold (or past the depth limit), rolled up.
        var hiddenCount: Int = 0
        var hiddenBytes: Int64 = 0
    }

    static let defaultMinSize: Int64 = 10 << 20
}

extension FileTree {
    func digest(
        rootPath: String,
        date: Date = Date(),
        minSize: Int64 = ScanDigest.defaultMinSize,
        maxDepth: Int = 12,
        volume: VolumeCapacity? = nil
    ) -> ScanDigest {
        var entries: [ScanDigest.Entry] = []
        func visit(_ id: NodeID, path: String, depth: Int) {
            var entry = ScanDigest.Entry(path: path, size: size(of: id), isDir: isDirectory(id), depth: depth)
            let index = entries.count
            entries.append(entry)
            guard entry.isDir else { return }
            let prefix = path.directoryPrefix
            for child in childrenSortedForDisplay(of: id) {
                let childSize = size(of: child)
                if depth < maxDepth && childSize >= minSize {
                    visit(child, path: prefix + name(of: child), depth: depth + 1)
                } else {
                    entry.hiddenCount += 1
                    entry.hiddenBytes += childSize
                }
            }
            entries[index].hiddenCount = entry.hiddenCount
            entries[index].hiddenBytes = entry.hiddenBytes
        }
        visit(Self.rootID, path: rootPath, depth: 0)
        return ScanDigest(
            rootPath: rootPath, date: date, totalBytes: size(of: Self.rootID),
            volumeCapacity: volume?.total, volumeAvailable: volume?.available,
            entries: entries
        )
    }
}

extension ScanDigest {
    /// Replaces the home folder prefix with `~` for anything that leaves the app.
    func redacted(home: String = UserHome.path) -> ScanDigest {
        var copy = self
        copy.rootPath = rootPath.abbreviatingHome(home)
        for i in copy.entries.indices { copy.entries[i].path = copy.entries[i].path.abbreviatingHome(home) }
        return copy
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> ScanDigest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScanDigest.self, from: data)
    }

    /// Indented tree for pasting into a chat. `limit` caps the number of lines.
    func markdown(limit: Int = 2_000) -> String {
        var lines = ["# Disk scan of `\(rootPath)`", ""]
        lines.append("- Scanned: \(date.formatted(date: .abbreviated, time: .shortened))")
        lines.append("- Total scanned: \(ByteFormatter.formatFileSize(totalBytes))")
        if let volumeCapacity, let volumeAvailable {
            lines.append("- Volume: \(ByteFormatter.formatFileSize(volumeCapacity)) total, \(ByteFormatter.formatFileSize(volumeAvailable)) available")
        }
        lines.append("- Items under \(ByteFormatter.formatFileSize(Self.defaultMinSize)) are rolled up per folder.")
        lines += ["", "```"]
        for entry in entries.prefix(limit) {
            let indent = String(repeating: "  ", count: entry.depth)
            let name = entry.depth == 0 ? entry.path : (entry.path as NSString).lastPathComponent
            var line = "\(indent)\(name)\(entry.isDir ? "/" : "")  \(ByteFormatter.formatFileSize(entry.size))"
            if entry.hiddenCount > 0 {
                line += "  (+\(entry.hiddenCount) smaller: \(ByteFormatter.formatFileSize(entry.hiddenBytes)))"
            }
            lines.append(line)
        }
        if entries.count > limit { lines.append("… \(entries.count - limit) more entries omitted") }
        lines.append("```")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Comparison

extension ScanDigest {
    struct Change: Sendable, Hashable, Identifiable {
        var path: String
        var oldSize: Int64?
        var newSize: Int64?
        var isDir: Bool
        var id: String { path }
        var delta: Int64 { (newSize ?? 0) - (oldSize ?? 0) }
    }

    /// Per-path size changes from `old` to `self`, largest absolute delta first.
    /// Paths below the digest threshold in one snapshot count as missing there.
    func diff(from old: ScanDigest) -> [Change] {
        let before = Dictionary(old.entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var changes: [Change] = []
        for (path, entry) in after where entry.depth > 0 {
            let oldSize = before[path]?.size
            if oldSize != entry.size {
                changes.append(Change(path: path, oldSize: oldSize, newSize: entry.size, isDir: entry.isDir))
            }
        }
        for (path, entry) in before where entry.depth > 0 && after[path] == nil {
            changes.append(Change(path: path, oldSize: entry.size, newSize: nil, isDir: entry.isDir))
        }
        return changes.sorted { abs($0.delta) == abs($1.delta) ? $0.path < $1.path : abs($0.delta) > abs($1.delta) }
    }

    /// Drops a folder's change when one of its descendants explains ≥90% of it,
    /// so "~/Library +5 GB" gives way to "~/Library/Caches/X +5 GB".
    static func mostSpecific(_ changes: [Change]) -> [Change] {
        let byPath = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var redundant = Set<String>()
        for change in changes {
            var parent = (change.path as NSString).deletingLastPathComponent
            while parent.count > 1, let ancestor = byPath[parent] {
                if (ancestor.delta > 0) == (change.delta > 0), abs(change.delta) * 10 >= abs(ancestor.delta) * 9 {
                    redundant.insert(parent)
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return changes.filter { !redundant.contains($0.path) }
    }
}

extension FileTree {
    /// Rebuilds a coarse tree from a digest; each folder's rolled-up remainder becomes one
    /// placeholder file so totals still match. Used where only history is available (MCP).
    init(digest: ScanDigest) {
        self.init(rootName: digest.rootPath)
        var ids: [String: NodeID] = [digest.rootPath: Self.rootID]
        for entry in digest.entries {
            let id: NodeID
            if entry.depth == 0 {
                id = Self.rootID
            } else {
                let parentPath = (entry.path as NSString).deletingLastPathComponent
                guard let parent = ids[parentPath] else { continue }
                id = addNode(
                    name: (entry.path as NSString).lastPathComponent, parent: parent,
                    size: entry.isDir ? 0 : entry.size, isDirectory: entry.isDir
                )
            }
            ids[entry.path] = id
            if entry.isDir && entry.hiddenBytes > 0 {
                addNode(name: Self.rolledUpName(entry.hiddenCount), parent: id, size: entry.hiddenBytes, isDirectory: false)
            }
        }
        rollUpDirectorySizes()
    }

    static func rolledUpName(_ count: Int) -> String { "(\(count) smaller items)" }
}
