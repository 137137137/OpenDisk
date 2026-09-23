import Darwin
import Foundation

enum ScanCache {
    struct Entry {
        let tree: FileTree
        let eventID: UInt64
    }

    private static let formatVersion: UInt32 = 2

    static func load(forRoot rootPath: String) -> Entry? {
        guard let url = cacheFileURL(forRoot: rootPath),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let header = parseHeader(data, forRoot: rootPath),
              let tree = FileTree(serializedData: data[header.treeStart...]) else {
            return nil
        }
        return Entry(tree: tree, eventID: header.eventID)
    }

    static func peek(forRoot rootPath: String) -> (eventID: UInt64, fileBytes: Int)? {
        guard let url = cacheFileURL(forRoot: rootPath),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let header = parseHeader(data, forRoot: rootPath) else { return nil }
        return (header.eventID, data.count)
    }

    private static func parseHeader(
        _ data: Data, forRoot rootPath: String
    ) -> (eventID: UInt64, treeStart: Data.Index)? {
        var offset = data.startIndex
        func read<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.endIndex else { return nil }
            defer { offset += size }
            return data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset - data.startIndex, as: T.self)
            }
        }

        guard read(UInt32.self) == formatVersion,
              let eventID = read(UInt64.self),
              let savedDevice = read(UInt64.self),
              let pathLength = read(UInt32.self),
              offset + Int(pathLength) <= data.endIndex else { return nil }

        let savedPath = String(decoding: data[offset..<(offset + Int(pathLength))], as: UTF8.self)
        offset += Int(pathLength)

        guard savedPath == rootPath,
              let device = VolumeAttributes.deviceID(ofPath: rootPath),
              UInt64(bitPattern: Int64(device)) == savedDevice else {
            return nil
        }
        return (eventID, offset)
    }

    static func save(tree: FileTree, forRoot rootPath: String, eventID: UInt64) {
        guard let url = cacheFileURL(forRoot: rootPath),
              let device = VolumeAttributes.deviceID(ofPath: rootPath) else { return }

        var header = Data()
        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { header.append(contentsOf: $0) }
        }
        append(formatVersion)
        append(eventID)
        append(UInt64(bitPattern: Int64(device)))
        let pathBytes = Data(rootPath.utf8)
        append(UInt32(pathBytes.count))
        header.append(pathBytes)

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { return }
        guard let handle = try? FileHandle(forWritingTo: temporary) else {
            try? FileManager.default.removeItem(at: temporary)
            return
        }
        do {
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: tree.serializedData())
            try handle.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            prune(directory: directory, keeping: url)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    private static let maxCacheFiles = 8
    private static let maxCacheBytes: Int64 = 4 << 30

    private static func prune(directory: URL, keeping justWritten: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        ) else { return }

        var caches: [(url: URL, modified: Date, size: Int64)] = []
        for url in entries {
            let values = try? url.resourceValues(forKeys: keys)
            let modified = values?.contentModificationDate ?? .distantPast
            if url.pathExtension == "tmp" {
                if modified < Date(timeIntervalSinceNow: -3600) {
                    try? FileManager.default.removeItem(at: url)
                }
                continue
            }
            guard url.pathExtension == "dmscan" else { continue }
            caches.append((url, modified, Int64(values?.fileSize ?? 0)))
        }

        caches.sort { $0.modified > $1.modified }
        var kept = 0
        var bytes: Int64 = 0
        for entry in caches {
            kept += 1
            bytes += entry.size
            if (kept > maxCacheFiles || bytes > maxCacheBytes),
               entry.url != justWritten {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    private static func cacheFileURL(forRoot rootPath: String) -> URL? {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? "OpenDisk"
        return caches
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("ScanCache", isDirectory: true)
            .appendingPathComponent("\(stableHash(rootPath)).dmscan")
    }

    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }
}
