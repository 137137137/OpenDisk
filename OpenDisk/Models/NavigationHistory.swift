import Foundation

struct NavigationHistory: Equatable, Sendable {
    private(set) var forwardStack: [String] = []

    var canGoForward: Bool { !forwardStack.isEmpty }
    var forwardTarget: String? { forwardStack.last }

    static func parent(of current: String, root: String) -> String? {
        guard current != root else { return nil }
        if current.hasPrefix("::") { return root }
        let parent = (current as NSString).deletingLastPathComponent
        guard parent.hasPrefix(root.directoryPrefix) || parent == root else { return root }
        return parent
    }

    mutating func didGoBack(from current: String) {
        forwardStack.append(current)
    }

    mutating func goForward() -> String? {
        forwardStack.popLast()
    }

    mutating func didNavigate(to path: String) {
        if forwardStack.last == path {
            forwardStack.removeLast()
        } else {
            forwardStack.removeAll()
        }
    }

    mutating func reset() {
        forwardStack.removeAll()
    }

    static func childLeading(to origin: String, from destination: String) -> String? {
        let prefix = destination.directoryPrefix
        guard origin.hasPrefix(prefix), origin.count > prefix.count else { return nil }
        guard let first = origin.dropFirst(prefix.count).split(separator: "/").first else {
            return nil
        }
        return prefix + first
    }
}
