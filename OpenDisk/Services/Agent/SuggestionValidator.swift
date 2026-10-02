import Foundation

/// Deterministic safeguards applied to every suggestion, whatever produced it.
/// The model's path, size and risk are never trusted as-is.
enum SuggestionValidator {
    /// Never suggested, even if `ProtectedPaths` would allow a subfolder.
    private static let systemAreas = ["/System", "/usr", "/bin", "/sbin", "/private", "/etc", "/var", "/dev", "/cores"]

    /// `checkDisk` also drops paths that no longer exist (stale scans); tests turn it off.
    static func validate(
        _ suggestions: [Suggestion], in scan: ScanResult,
        home: String = UserHome.path, checkDisk: Bool = true
    ) -> SuggestionReport {
        var accepted: [ValidatedSuggestion] = []
        var rejected: [RejectedSuggestion] = []

        for suggestion in suggestions {
            let path = expand(suggestion.path, home: home)
            func reject(_ reason: String) { rejected.append(RejectedSuggestion(path: path, reason: reason)) }

            if let reason = ProtectedPaths.reason(for: path) { reject("It \(reason)."); continue }
            if systemAreas.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                reject("It's inside a macOS system area."); continue
            }
            if home.hasPrefix(path + "/") { reject("It contains your home folder."); continue }
            guard let node = scan.tree.nodeID(forPath: path, rootPath: scan.rootPath) else {
                reject("It isn't in this scan."); continue
            }
            let size = scan.tree.size(of: node)
            guard size > 0 else { reject("It takes up no space."); continue }
            if checkDisk && !FileManager.default.fileExists(atPath: path) {
                reject("It no longer exists on disk."); continue
            }

            let (floor, why) = ruleRisk(for: path, node: node, in: scan.tree, home: home)
            let risk = max(suggestion.risk, floor)
            accepted.append(ValidatedSuggestion(
                suggestion: suggestion, path: path, size: size,
                isDirectory: scan.tree.isDirectory(node), risk: risk,
                riskRaisedReason: risk > suggestion.risk ? why : nil
            ))
        }

        // Drop duplicates and items nested in another suggestion so sizes aren't double counted.
        let paths = Set(accepted.map(\.path))
        var seen = Set<String>()
        accepted = accepted.filter { item in
            guard seen.insert(item.path).inserted else { return false }
            var parent = (item.path as NSString).deletingLastPathComponent
            while parent.count > 1 {
                if paths.contains(parent) {
                    rejected.append(RejectedSuggestion(path: item.path, reason: "Already covered by \(parent)."))
                    return false
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
        accepted.sort { $0.risk == $1.risk ? $0.size > $1.size : $0.risk < $1.risk }
        return SuggestionReport(accepted: accepted, rejected: rejected)
    }

    /// The lowest risk OpenDisk allows for `path`, with the reason when it isn't low.
    static func ruleRisk(
        for path: String, node: FileTree.NodeID, in tree: FileTree, home: String = UserHome.path
    ) -> (Risk, String?) {
        func inside(_ base: String) -> Bool { path == base || path.hasPrefix(base + "/") }

        let personal = [
            "/Documents", "/Desktop", "/Pictures", "/Movies", "/Music",
            "/Library/Mail", "/Library/Messages", "/Library/Mobile Documents",
            "/Library/Containers", "/Library/Group Containers", "/Library/Application Support",
            "/Library/Keychains",
        ].map { home + $0 }
        if let base = personal.first(where: inside) {
            return (.high, "\((base as NSString).lastPathComponent) holds personal or app data.")
        }
        let components = path.split(separator: "/")
        if components.contains(where: { $0.hasSuffix(".photoslibrary") || $0.hasSuffix(".musiclibrary") }) {
            return (.high, "It's part of a Photos or Music library.")
        }
        if inside("/Applications") { return (.high, "It's an installed app.") }
        if insideGitRepository(node, in: tree) { return (.high, "It's inside a Git repository.") }

        if CleanableCacheCatalog.locations.contains(where: { inside($0.path) }) { return (.low, nil) }
        if inside("/Library") || inside("/opt") { return (.high, "It's in a shared system location.") }
        return (.medium, "OpenDisk doesn't recognise it as a known cache.")
    }

    // ponytail: checks the item and its ancestors only; a folder containing repos deeper down
    // stays medium. Walk descendants if that turns out to matter.
    private static func insideGitRepository(_ node: FileTree.NodeID, in tree: FileTree) -> Bool {
        var current = node
        while current != FileTree.noNode {
            if tree.isDirectory(current), tree.child(of: current, named: ".git") != nil { return true }
            current = tree.parent(of: current)
        }
        return false
    }

    static func expand(_ path: String, home: String = UserHome.path) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst() }
        p = (p as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
