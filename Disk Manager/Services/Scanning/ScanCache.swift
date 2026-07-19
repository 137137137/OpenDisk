import Darwin
import Foundation

/// On-disk cache of finished scan trees, keyed by scan root, together
/// with the FSEvents event ID captured when the scan started. A later
/// scan of the same root can replay the volume's FSEvents journal from
/// that ID and re-read only the directories that changed since.
enum ScanCache {

    struct Entry {
        /// The cached tree, with directory sizes NOT rolled up (ready for
        /// splicing and a fresh roll-up).
        let tree: FileTree
        /// FSEvents ID from just before the cached scan began.
        let eventID: UInt64
    }

    private static let formatVersion: UInt32 = 1

    // MARK: - Public API

    static func load(forRoot rootPath: String) -> Entry? {
        guard let url = cacheFileURL(forRoot: rootPath),
              let data = try? Data(contentsOf: url) else { return nil }

        var offset = 0
        func read<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            defer { offset += size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }

        guard read(UInt32.self) == formatVersion,
              let eventID = read(UInt64.self),
              let savedDevice = read(UInt64.self),
              let pathLength = read(UInt32.self),
              offset + Int(pathLength) <= data.count else { return nil }

        let savedPath = String(decoding: data[offset..<(offset + Int(pathLength))], as: UTF8.self)
        offset += Int(pathLength)

        // The cache must describe this exact root on this exact volume —
        // a re-formatted or different disk mounted at the same place must
        // not resurrect a stale tree.
        guard savedPath == rootPath,
              let device = VolumeAttributes.deviceID(ofPath: rootPath),
              UInt64(bitPattern: Int64(device)) == savedDevice,
              let tree = FileTree(serializedData: data.subdata(in: offset..<data.count)) else {
            return nil
        }
        return Entry(tree: tree, eventID: eventID)
    }

    /// Blocking (~hundreds of ms for multi-million-node trees): call from
    /// a background queue.
    static func save(tree: FileTree, forRoot rootPath: String, eventID: UInt64) {
        guard let url = cacheFileURL(forRoot: rootPath),
              let device = VolumeAttributes.deviceID(ofPath: rootPath) else { return }

        var data = Data()
        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        append(formatVersion)
        append(eventID)
        append(UInt64(bitPattern: Int64(device)))
        let pathBytes = Data(rootPath.utf8)
        append(UInt32(pathBytes.count))
        data.append(pathBytes)
        data.append(tree.serializedData())

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Location

    private static func cacheFileURL(forRoot rootPath: String) -> URL? {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? "DiskManager"
        return caches
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("ScanCache", isDirectory: true)
            .appendingPathComponent("\(stableHash(rootPath)).dmscan")
    }

    /// FNV-1a: stable across launches (unlike `Hasher`) and collision-safe
    /// enough for a handful of scan roots; the root path stored inside the
    /// file is the authoritative check.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }
}
