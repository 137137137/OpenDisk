import Foundation

extension String {
    var directoryPrefix: String {
        hasSuffix("/") ? self : self + "/"
    }

    /// Replaces a leading home folder with `~`.
    func abbreviatingHome(_ home: String = UserHome.path) -> String {
        if self == home { return "~" }
        return hasPrefix(home + "/") ? "~" + dropFirst(home.count) : self
    }
}
