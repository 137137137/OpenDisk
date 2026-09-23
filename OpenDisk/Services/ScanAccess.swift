import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ScanAccess {
    nonisolated static let isSandboxed =
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    struct Grant: Identifiable, Hashable {
        let path: String
        let name: String
        var id: String { path }
    }

    private(set) var grants: [Grant] = []

    private let defaultsKey = "granted_scan_bookmarks"
    private var bookmarks: [String: Data] = [:]
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

    func isGranted(_ path: String) -> Bool { bookmarks[path] != nil }

    func requestGrant(startingAt startURL: URL? = nil, suggestedName: String? = nil) -> Grant? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if let suggestedName {
            panel.message = "Select “\(suggestedName)” to let OpenDisk scan it, then click Scan. "
                + "OpenDisk remembers your choice, so next time it's one click."
        } else {
            panel.message = "Choose what to scan. To analyze your whole Mac, pick your startup disk "
                + "(e.g. “Macintosh HD”) from the sidebar. You can also choose any folder or volume. "
                + "OpenDisk remembers your choice."
        }
        panel.directoryURL = startURL ?? URL(fileURLWithPath: "/")
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
        if stale { store(url) }
        return true
    }

    func endAccess(toPath path: String) {
        guard let root = Self.longestRoot(containing: path, in: accessing.keys),
              let url = accessing[root] else { return }
        url.stopAccessingSecurityScopedResource()
        accessing[root] = nil
    }

    private func grantRoot(containing path: String) -> String? {
        Self.longestRoot(containing: path, in: bookmarks.keys)
    }

    private static func longestRoot(
        containing path: String, in roots: some Sequence<String>
    ) -> String? {
        roots
            .filter { root in
                path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
            .max { $0.count < $1.count }
    }

    private static func displayName(for path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    private func save() {
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
    }
}
