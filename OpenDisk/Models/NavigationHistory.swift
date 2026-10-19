import Foundation

/// Back and Forward for the folder list, browser style.
///
/// Back always goes up one level, toward the scan root, and is unavailable at
/// the root. Forward re-enters whatever Back just left, one level at a time.
/// Any other navigation (clicking a folder, a breadcrumb, a search result)
/// drops the forward history unless it happens to be the next forward step.
struct NavigationHistory: Equatable, Sendable {
    private(set) var forwardStack: [String] = []

    var canGoForward: Bool { !forwardStack.isEmpty }
    var forwardTarget: String? { forwardStack.last }

    /// The folder Back goes to from `current`, or nil at the root.
    static func parent(of current: String, root: String) -> String? {
        guard current != root else { return nil }
        if current.hasPrefix("::") { return root }
        let parent = (current as NSString).deletingLastPathComponent
        guard parent.hasPrefix(root.directoryPrefix) || parent == root else { return root }
        return parent
    }

    /// Records that Back left `current`, so Forward can return to it.
    mutating func didGoBack(from current: String) {
        forwardStack.append(current)
    }

    /// Takes the next Forward step, if any.
    mutating func goForward() -> String? {
        forwardStack.popLast()
    }

    /// Call for every navigation that isn't Back or Forward.
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

    /// When moving from `origin` up to its ancestor `destination`, the child
    /// of `destination` that leads back to `origin`. Highlighting it after
    /// going back keeps the user's place in the list, as Finder does.
    static func childLeading(to origin: String, from destination: String) -> String? {
        let prefix = destination.directoryPrefix
        guard origin.hasPrefix(prefix), origin.count > prefix.count else { return nil }
        guard let first = origin.dropFirst(prefix.count).split(separator: "/").first else {
            return nil
        }
        return prefix + first
    }
}
