import Foundation

extension String {
    var directoryPrefix: String {
        hasSuffix("/") ? self : self + "/"
    }
}
