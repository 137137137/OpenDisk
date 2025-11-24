import Foundation

/// A utility class for consistent path filtering and skip logic across the application
enum PathFilter {

    // MARK: - System Paths

    /// Core system paths that should never be deeply scanned
    private static let systemPaths = [
        "/System",
        "/Library",
        "/private",
        "/usr",
        "/bin",
        "/sbin",
        "/cores",
        "/dev",
        "/etc",
        "/var",
        "/tmp"
    ]

    /// Virtual file system and special paths to skip completely
    private static let virtualPaths = [
        "/dev",
        "/proc",
        "/sys",
        "/tmp",
        "/var/run",
        "/var/tmp",
        "/var/folders",
        "/.Spotlight-V100",
        "/.Trashes",
        "/System/Volumes/Data/.Trashes"
    ]

    /// System directory names to skip during cleanup
    private static let systemDirectoryNames = [
        "System",
        "Library",
        "usr",
        "bin",
        "sbin",
        "private",
        "etc",
        "var",
        "tmp",
        "cores",
        "dev",
        ".vol",
        ".DocumentRevisions-V100",
        ".Spotlight-V100",
        ".fseventsd",
        ".Trashes",
        "Applications",
        ".app",
        "node_modules",
        ".git",
        ".svn",
        ".hg"
    ]

    // MARK: - Public Methods

    /// Checks if a path should be skipped during deep system scanning
    static func shouldSkipDeepSystemScan(_ path: String) -> Bool {
        // Check if path is or is under a system directory
        for systemPath in systemPaths {
            if path == systemPath || path.hasPrefix(systemPath + "/") {
                return true
            }
        }

        // Also skip .app bundles and packages
        if path.contains(".app/") || path.hasSuffix(".app") {
            return true
        }

        return false
    }

    /// Checks if a path should be skipped entirely (virtual filesystems, etc.)
    static func shouldSkipPath(_ path: String) -> Bool {
        for skipPath in virtualPaths {
            if path == skipPath || path.hasPrefix(skipPath + "/") {
                return true
            }
        }
        return false
    }

    /// Checks if a directory name should be skipped during cleanup operations
    static func shouldSkipDirectoryForCleanup(_ name: String) -> Bool {
        return systemDirectoryNames.contains { skip in
            name == skip || name.hasSuffix(skip)
        }
    }

    /// Checks if a path is a system volume
    static func isSystemVolume(_ path: String) -> Bool {
        return path.hasPrefix("/System") ||
               (path.hasPrefix("/") && !path.hasPrefix("/Volumes/") && !path.contains("/Users/"))
    }

    /// Checks if a volume name should be skipped
    static func shouldSkipVolume(_ volumeName: String) -> Bool {
        return volumeName.hasPrefix(".") ||
               volumeName == "Macintosh HD" ||
               volumeName.contains("com.apple.TimeMachine")
    }
}