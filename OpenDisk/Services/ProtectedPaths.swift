import Foundation

enum ProtectedPaths {
    private static let systemRoots: Set<String> = [
        "/", "/System", "/Library", "/usr", "/bin", "/sbin", "/private",
        "/etc", "/var", "/tmp", "/cores", "/opt", "/dev", "/Network",
        "/Volumes", "/Applications", "/Users",
        "/System/Volumes", "/System/Applications", "/System/Library",
    ]

    static func reason(for path: String) -> String? {
        let p = normalized(path)

        if p == "/" { return "is the disk root and can't be deleted" }
        if systemRoots.contains(p) { return "is a macOS system folder and can't be deleted" }

        // Real home: in the sandbox NSHomeDirectory() is the container, leaving ~/Library unprotected.
        let home = normalized(UserHome.path)
        if p == home { return "is your home folder and can't be deleted" }
        if p == home + "/Library" { return "is your Library and can't be deleted" }

        switch parent(of: p) {
        case "/Users":          return "is a user account folder and can't be deleted"
        case "/Volumes":        return "is a mounted volume and can't be deleted"
        case "/System/Volumes": return "is a macOS system volume and can't be deleted"
        default: break
        }

        for root in systemRoots where root.hasPrefix(p + "/") {
            return "contains macOS system files and can't be deleted"
        }
        if home.hasPrefix(p + "/") { return "contains your home folder and can't be deleted" }

        return nil
    }

    static func isProtected(_ path: String) -> Bool { reason(for: path) != nil }

    private static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}
