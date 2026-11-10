import Foundation

final class ScanFocus: Sendable {
    struct Snapshot: Equatable, Sendable {
        var version = 0
        var prefixes: [String] = []

        func contains(_ path: String) -> Bool {
            prefixes.contains { prefix in
                path == prefix || path.hasPrefix(prefix + "/")
            }
        }
    }

    private static let dataVolumeMountPoint = "/System/Volumes/Data"

    private let state = Mutex(Snapshot())

    var snapshot: Snapshot { state.withLock { $0 } }

    func focus(on path: String?) {
        let prefixes: [String]
        if let path, path.hasPrefix("/"), path != "/" {
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            prefixes = trimmed.hasPrefix(Self.dataVolumeMountPoint + "/")
                ? [trimmed, String(trimmed.dropFirst(Self.dataVolumeMountPoint.count))]
                : [trimmed, Self.dataVolumeMountPoint + trimmed]
        } else {
            prefixes = []
        }
        state.withLock { snapshot in
            guard snapshot.prefixes != prefixes else { return }
            snapshot.prefixes = prefixes
            snapshot.version &+= 1
        }
    }
}
