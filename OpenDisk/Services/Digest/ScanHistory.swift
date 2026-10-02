import Foundation

/// Local, unredacted `ScanDigest` snapshots per scan root, for comparing scans over time.
/// Files are named `<epoch>-<totalBytes>.json` so listing never has to decode them.
enum ScanHistory {
    struct Item: Sendable, Hashable, Identifiable {
        let date: Date
        let totalBytes: Int64
        let url: URL
        var id: URL { url }
    }

    /// `base` replaces Application Support/<bundle ID> (tests).
    static func rootDirectory(base: URL? = nil) -> URL? {
        guard let base = base ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.appendingPathComponent(AppIdentity.bundleID, isDirectory: true) else { return nil }
        return base.appendingPathComponent("History", isDirectory: true)
    }

    static func directory(forRoot rootPath: String, base: URL? = nil) -> URL? {
        rootDirectory(base: base)?.appendingPathComponent(ScanCache.stableHash(rootPath), isDirectory: true)
    }

    static func list(root rootPath: String, base: URL? = nil) -> [Item] {
        guard let directory = directory(forRoot: rootPath, base: base),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              ) else { return [] }
        return urls.compactMap { url -> Item? in
            guard url.pathExtension == "json" else { return nil }
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard parts.count == 2, let epoch = TimeInterval(parts[0]), let total = Int64(parts[1]) else { return nil }
            return Item(date: Date(timeIntervalSince1970: epoch), totalBytes: total, url: url)
        }
        .sorted { $0.date > $1.date }
    }

    static func load(_ item: Item) -> ScanDigest? {
        (try? Data(contentsOf: item.url)).flatMap { try? ScanDigest.decode($0) }
    }

    /// Saves unless the newest snapshot is under 10 minutes old and within 0.1% in size.
    @discardableResult
    static func save(_ digest: ScanDigest, base: URL? = nil) -> Bool {
        guard let directory = directory(forRoot: digest.rootPath, base: base) else { return false }
        let existing = list(root: digest.rootPath, base: base)
        if let last = existing.first,
           digest.date.timeIntervalSince(last.date) < 600,
           abs(Double(digest.totalBytes - last.totalBytes)) <= Double(max(last.totalBytes, 1)) * 0.001 {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "\(Int(digest.date.timeIntervalSince1970))-\(digest.totalBytes).json"
            try digest.jsonData().write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            return false
        }
        prune(root: digest.rootPath, base: base, now: digest.date)
        return true
    }

    static let maxSnapshots = 200

    /// Keeps everything from the last 30 days, then one snapshot per week, at most `maxSnapshots`.
    static func prune(root rootPath: String, base: URL? = nil, now: Date = Date()) {
        let items = list(root: rootPath, base: base)
        var seenWeeks = Set<Int>()
        var kept = 0
        for item in items {
            let age = now.timeIntervalSince(item.date)
            let week = Int(item.date.timeIntervalSince1970 / (7 * 86_400))
            let keep = kept < maxSnapshots && (age < 30 * 86_400 || seenWeeks.insert(week).inserted)
            if keep { kept += 1 } else { try? FileManager.default.removeItem(at: item.url) }
        }
    }
}
