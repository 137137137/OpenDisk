import Foundation

/// The user's real home directory (e.g. "/Users/alice").
///
/// Inside the App Sandbox (the Mac App Store build) `NSHomeDirectory()`
/// points at the app's *container* — so anything that reasons about the
/// user's actual files (protected paths, cache catalogs) must resolve the
/// true home through the passwd database instead.
enum UserHome {
    static let path: String = {
        if let passwd = getpwuid(getuid()), let dir = passwd.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()
}
