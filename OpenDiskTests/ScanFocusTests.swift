import Foundation
import Testing
@testable import OpenDisk

@Suite("Scan focus")
struct ScanFocusTests {
    private func item(_ path: String) -> TraversalScanner.WorkItem {
        TraversalScanner.WorkItem(directoryID: FileTree.rootID, path: path)
    }

    private func drain(_ state: TraversalScanner.WorkState) -> [String] {
        var paths: [String] = []
        while let next = state.pop() { paths.append(next.path) }
        return paths
    }

    @Test("a focused folder matches itself, its descendants and its Data volume alias")
    func prefixMatching() {
        let focus = ScanFocus()
        focus.focus(on: "/Users/me/Library")
        let snapshot = focus.snapshot
        #expect(snapshot.contains("/Users/me/Library"))
        #expect(snapshot.contains("/Users/me/Library/Caches"))
        #expect(snapshot.contains("/System/Volumes/Data/Users/me/Library/Caches"))
        #expect(!snapshot.contains("/Users/me/LibraryOld"))
        #expect(!snapshot.contains("/Users/me"))
    }

    @Test("focusing the scan root or nothing clears the focus")
    func clearing() {
        let focus = ScanFocus()
        focus.focus(on: "/Users/me")
        focus.focus(on: "/")
        #expect(focus.snapshot.prefixes.isEmpty)
        focus.focus(on: "/Users/me")
        focus.focus(on: nil)
        #expect(focus.snapshot.prefixes.isEmpty)
    }

    @Test("without a focus, folders come out last in, first out")
    func unfocusedOrder() {
        let state = TraversalScanner.WorkState(maxWorkers: 1, focus: ScanFocus())
        _ = state.push([item("/a"), item("/b"), item("/c")])
        #expect(drain(state) == ["/c", "/b", "/a"])
    }

    @Test("folders already queued inside the focused folder jump ahead")
    func queuedFoldersJumpAhead() {
        let focus = ScanFocus()
        let state = TraversalScanner.WorkState(maxWorkers: 1, focus: focus)
        _ = state.push([item("/a/1"), item("/b/1"), item("/a/2"), item("/c/1")])
        focus.focus(on: "/b")
        #expect(state.pop()?.path == "/b/1")
        #expect(drain(state) == ["/c/1", "/a/2", "/a/1"])
    }

    @Test("folders discovered inside the focused folder are scanned before the rest")
    func discoveredFoldersGoFirst() {
        let focus = ScanFocus()
        let state = TraversalScanner.WorkState(maxWorkers: 1, focus: focus)
        _ = state.push([item("/a"), item("/b")])
        focus.focus(on: "/a")
        #expect(state.pop()?.path == "/a")
        _ = state.push([item("/a/x"), item("/a/y")])
        _ = state.push([item("/z")])
        #expect(drain(state) == ["/a/y", "/a/x", "/z", "/b"])
    }

    @Test("clearing the focus puts everything back in one queue")
    func clearingRestoresOrder() {
        let focus = ScanFocus()
        let state = TraversalScanner.WorkState(maxWorkers: 1, focus: focus)
        focus.focus(on: "/a")
        _ = state.pop()
        _ = state.push([item("/a/1"), item("/b/1")])
        focus.focus(on: nil)
        #expect(Set(drain(state)) == ["/a/1", "/b/1"])
    }
}
