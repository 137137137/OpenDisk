import AppKit
import Foundation
import Observation

/// Bridges the two distribution builds' file-access models:
///   • Website (non-sandboxed): Full Disk Access — scan any path directly.
///   • App Store (sandboxed): scan only folders/volumes the user grants through
///     an open panel, remembered across launches via security-scoped bookmarks.
///
/// Everything sandbox-specific is gated on `isSandboxed` (a runtime check), so
/// the identical code ships in both targets — the website build simply never
/// enters the grant path (`beginAccess` is a no-op that always succeeds).
@MainActor
@Observable
final class ScanAccess {

    /// True when running inside the App Sandbox — i.e. the Mac App Store build.
    nonisolated static let isSandboxed =
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// A location the user has granted, re-openable without re-granting.
    struct Grant: Identifiable, Hashable {
        let path: String
        let name: String
        var id: String { path }
    }

    private(set) var grants: [Grant] = []

    private let defaultsKey = "granted_scan_bookmarks"
    /// Granted root path → its security-scoped bookmark.
    private var bookmarks: [String: Data] = [:]
    /// Granted roots we've begun accessing, so `stopAccessing` stays balanced.
    private var accessing: [String: URL] = [:]

    init() {
        guard Self.isSandboxed else { return }
        if let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] {
            bookmarks = stored
            grants = stored.keys
                .map { Grant(path: $0, name: Self.displayName(for: $0)) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: - Granting

    /// Asks the user to choose a folder or volume, stores a security-scoped
    /// bookmark for it, and returns the grant. Nil if the user cancels.
    func requestGrant() -> Grant? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant Access"
        panel.message = "Choose a folder or volume for OpenDisk to scan. It will remember your choice."
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return store(url)
    }

    func removeGrant(_ grant: Grant) {
        endAccess(toPath: grant.path)
        bookmarks[grant.path] = nil
        grants.removeAll { $0.path == grant.path }
        save()
    }

    @discardableResult
    private func store(_ url: URL) -> Grant? {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil
        ) else { return nil }

        let path = url.path
        bookmarks[path] = data
        save()

        let grant = Grant(path: path, name: Self.displayName(for: path))
        grants.removeAll { $0.path == path }
        grants.insert(grant, at: 0)
        return grant
    }

    // MARK: - Access lifetime

    /// Starts security-scoped access to the granted root containing `path`, so
    /// a scan can read it and its subtree. Returns true when access is
    /// available — always true outside the sandbox.
    @discardableResult
    func beginAccess(toPath path: String) -> Bool {
        guard Self.isSandboxed else { return true }
        guard let root = grantRoot(containing: path) else { return false }
        if accessing[root] != nil { return true }
        guard let data = bookmarks[root] else { return false }

        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &stale
        ), url.startAccessingSecurityScopedResource() else { return false }

        accessing[root] = url
        if stale { store(url) }   // refresh a bookmark macOS marked stale
        return true
    }

    func endAccess(toPath path: String) {
        guard let root = grantRoot(containing: path), let url = accessing[root] else { return }
        url.stopAccessingSecurityScopedResource()
        accessing[root] = nil
    }

    // MARK: - Helpers

    /// The granted root whose subtree contains `path` (or equals it).
    private func grantRoot(containing path: String) -> String? {
        bookmarks.keys.first { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    private static func displayName(for path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    private func save() {
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
    }
}
