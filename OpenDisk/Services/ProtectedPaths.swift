import Foundation

/// Guards against collecting macOS-critical locations for deletion — the disk
/// root, system folders, whole user accounts, `~/Library`, and mounted-volume
/// roots. Deleting any of these would break the system or wipe an account, so
/// the Collector refuses them (mirroring DaisyDisk's protection).
enum ProtectedPaths {
    /// Absolute directories that must never be deleted.
    private static let systemRoots: Set<String> = [
        "/", "/System", "/Library", "/usr", "/bin", "/sbin", "/private",
        "/etc", "/var", "/tmp", "/cores", "/opt", "/dev", "/Network",
        "/Volumes", "/Applications", "/Users",
        "/System/Volumes", "/System/Applications", "/System/Library",
    ]

    /// A human-readable reason if `path` is protected, otherwise `nil`.
    /// The message is phrased to follow the item's name, e.g.
    /// `"System" ` + `"is a macOS system folder…"`.
    static func reason(for path: String) -> String? {
        let p = normalized(path)

        if p == "/" { return "is the disk root and can't be deleted" }
        if systemRoots.contains(p) { return "is a macOS system folder and can't be deleted" }

        // The *real* home — in the sandboxed build NSHomeDirectory() is the
        // app container, which would leave the actual ~/Library unprotected.
        let home = normalized(UserHome.path)
        if p == home { return "is your home folder and can't be deleted" }
        if p == home + "/Library" { return "is your Library and can't be deleted" }

        // A home root directly under /Users (e.g. /Users/alice, /Users/Shared).
        switch parent(of: p) {
        case "/Users":          return "is a user account folder and can't be deleted"
        case "/Volumes":        return "is a mounted volume and can't be deleted"
        case "/System/Volumes": return "is a macOS system volume and can't be deleted"
        default: break
        }

        // Any ancestor of a protected location is at least as dangerous.
        for root in systemRoots where root.hasPrefix(p + "/") {
            return "contains macOS system files and can't be deleted"
        }
        if home.hasPrefix(p + "/") { return "contains your home folder and can't be deleted" }

        return nil
    }

    static func isProtected(_ path: String) -> Bool { reason(for: path) != nil }

    // MARK: - Helpers

    private static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}
