import Foundation
import Testing
@testable import OpenDisk

@Suite("NavigationHistory")
struct NavigationHistoryTests {
    private let root = "/Volumes/External"

    @Test("Back goes up exactly one level")
    func backIsParent() {
        #expect(NavigationHistory.parent(of: root + "/a/b/c", root: root) == root + "/a/b")
        #expect(NavigationHistory.parent(of: root + "/a", root: root) == root)
    }

    @Test("Back is unavailable at the root")
    func noBackAtRoot() {
        #expect(NavigationHistory.parent(of: root, root: root) == nil)
        #expect(NavigationHistory.parent(of: "/", root: "/") == nil)
    }

    @Test("Back from a top-level folder of the boot volume returns to /")
    func bootVolume() {
        #expect(NavigationHistory.parent(of: "/Users", root: "/") == "/")
        #expect(NavigationHistory.parent(of: "/Users/me", root: "/") == "/Users")
    }

    @Test("Back from a synthetic row returns to the root")
    func syntheticRow() {
        #expect(NavigationHistory.parent(of: "::Caches", root: root) == root)
    }

    @Test("Back never leaves the scan root")
    func clampsToRoot() {
        #expect(NavigationHistory.parent(of: "/Volumes/Other/x", root: root) == root)
    }

    @Test("Forward re-enters each level Back left, in order")
    func forwardRetracesBack() {
        var history = NavigationHistory()
        var current = root + "/a/b"
        for _ in 0..<2 {
            let parent = NavigationHistory.parent(of: current, root: root)!
            history.didGoBack(from: current)
            current = parent
        }
        #expect(current == root)
        #expect(history.goForward() == root + "/a")
        #expect(history.goForward() == root + "/a/b")
        #expect(history.goForward() == nil)
        #expect(!history.canGoForward)
    }

    @Test("Opening the next Forward folder by hand keeps the rest of Forward")
    func manualForwardKeepsHistory() {
        var history = NavigationHistory()
        history.didGoBack(from: root + "/a/b")
        history.didGoBack(from: root + "/a")
        history.didNavigate(to: root + "/a")
        #expect(history.forwardTarget == root + "/a/b")
    }

    @Test("Going somewhere else clears Forward")
    func otherNavigationClearsForward() {
        var history = NavigationHistory()
        history.didGoBack(from: root + "/a")
        history.didNavigate(to: root + "/z")
        #expect(!history.canGoForward)
    }

    @Test("The folder you came from is highlighted after going up", arguments: [
        ("/Volumes/External/a/b/c", "/Volumes/External/a", "/Volumes/External/a/b"),
        ("/Volumes/External/a", "/Volumes/External", "/Volumes/External/a"),
        ("/Users/me/Downloads", "/", "/Users"),
    ])
    func childLeading(origin: String, destination: String, expected: String) {
        #expect(NavigationHistory.childLeading(to: origin, from: destination) == expected)
    }

    @Test("No highlight when the destination isn't an ancestor")
    func childLeadingUnrelated() {
        #expect(NavigationHistory.childLeading(to: root + "/a", from: root + "/b") == nil)
        #expect(NavigationHistory.childLeading(to: root + "/ab", from: root + "/a") == nil)
        #expect(NavigationHistory.childLeading(to: root, from: root) == nil)
    }
}
