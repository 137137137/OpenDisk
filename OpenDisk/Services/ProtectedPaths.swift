import Foundation

enum ProtectedPaths {
    private static let systemRoots: Set<String> = [
        "/", "/System", "/Library", "/usr", "/bin", "/sbin", "/private",
        "/etc", "/var", "/tmp", "/cores", "/opt", "/dev", "/Network",
        "/Volumes", "/Applications", "/Users",
        "/System/Volumes", "/System/Applications", "/System/Library",
    ]

    enum Reason: Equatable {
        case diskRoot
        case systemFolder
        case homeFolder
        case userLibrary
        case userAccount
        case mountedVolume
        case systemVolume
        case containsSystemFiles
        case containsHomeFolder
    }

    static func reason(for path: String) -> Reason? {
        let p = normalized(path)

        if p == "/" { return .diskRoot }
        if systemRoots.contains(p) { return .systemFolder }

        let home = normalized(UserHome.path)
        if p == home { return .homeFolder }
        if p == home + "/Library" { return .userLibrary }

        switch parent(of: p) {
        case "/Users":          return .userAccount
        case "/Volumes":        return .mountedVolume
        case "/System/Volumes": return .systemVolume
        default: break
        }

        for root in systemRoots where root.hasPrefix(p + "/") {
            return .containsSystemFiles
        }
        if home.hasPrefix(p + "/") { return .containsHomeFolder }

        return nil
    }

    static func message(for path: String, name: String) -> String? {
        switch reason(for: path) {
        case nil: nil
        case .diskRoot: String(localized: "“\(name)” is the disk root and can't be deleted")
        case .systemFolder: String(localized: "“\(name)” is a macOS system folder and can't be deleted")
        case .homeFolder: String(localized: "“\(name)” is your home folder and can't be deleted")
        case .userLibrary: String(localized: "“\(name)” is your Library and can't be deleted")
        case .userAccount: String(localized: "“\(name)” is a user account folder and can't be deleted")
        case .mountedVolume: String(localized: "“\(name)” is a mounted volume and can't be deleted")
        case .systemVolume: String(localized: "“\(name)” is a macOS system volume and can't be deleted")
        case .containsSystemFiles: String(localized: "“\(name)” contains macOS system files and can't be deleted")
        case .containsHomeFolder: String(localized: "“\(name)” contains your home folder and can't be deleted")
        }
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
