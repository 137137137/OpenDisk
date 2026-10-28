import Foundation
import Testing
@testable import OpenDisk

@Suite("ProtectedPaths")
struct ProtectedPathsTests {
    private var home: String {
        var h = (NSHomeDirectory() as NSString).standardizingPath
        while h.count > 1 && h.hasSuffix("/") { h.removeLast() }
        return h
    }

    @Test("the disk root is protected")
    func diskRoot() {
        #expect(ProtectedPaths.reason(for: "/") == .diskRoot)
        #expect(ProtectedPaths.reason(for: "///") == .diskRoot)
    }

    @Test("macOS system folders are protected", arguments: [
        "/System", "/Library", "/usr", "/bin", "/sbin", "/private",
        "/etc", "/var", "/tmp", "/cores", "/opt", "/dev", "/Network",
        "/Volumes", "/Applications", "/Users",
        "/System/Volumes", "/System/Applications", "/System/Library",
    ])
    func systemFolders(path: String) {
        #expect(ProtectedPaths.reason(for: path) == .systemFolder)
        #expect(ProtectedPaths.isProtected(path))
    }

    @Test("direct children of /Users are user account folders", arguments: [
        "/Users/alice", "/Users/somebody-else", "/Users/Shared",
    ])
    func userAccountRoots(path: String) {
        #expect(ProtectedPaths.reason(for: path) == .userAccount)
    }

    @Test("deep paths inside another user's account are not protected")
    func otherUsersDeepPaths() {
        #expect(ProtectedPaths.reason(for: "/Users/alice/Downloads") == nil)
        #expect(ProtectedPaths.reason(for: "/Users/Shared/Movies/big.mov") == nil)
    }

    @Test("the real user home is protected")
    func homeProtected() {
        #expect(ProtectedPaths.reason(for: home) == .homeFolder)
        #expect(ProtectedPaths.reason(for: home + "/") == .homeFolder)
    }

    @Test("the user's ~/Library is protected")
    func homeLibraryProtected() {
        #expect(ProtectedPaths.reason(for: home + "/Library") == .userLibrary)
        #expect(ProtectedPaths.reason(for: home + "/Library/") == .userLibrary)
    }

    @Test("tilde inputs expand to the home folder")
    func tildeExpansion() {
        #expect(ProtectedPaths.reason(for: "~") == .homeFolder)
        #expect(ProtectedPaths.reason(for: "~/Library") == .userLibrary)
    }

    @Test("every ancestor of the home folder is protected")
    func homeAncestorsProtected() {
        var ancestor = (home as NSString).deletingLastPathComponent
        while ancestor.count > 1 {
            #expect(ProtectedPaths.isProtected(ancestor), "\(ancestor) should be protected")
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        #expect(ProtectedPaths.isProtected("/"))
    }

    @Test("ordinary folders inside the home are not protected")
    func homeChildrenNotProtected() {
        #expect(ProtectedPaths.reason(for: home + "/Downloads") == nil)
        #expect(ProtectedPaths.reason(for: home + "/Downloads/foo") == nil)
        #expect(ProtectedPaths.reason(for: home + "/Documents/report.pdf") == nil)
        #expect(ProtectedPaths.reason(for: home + "/Library/Caches") == nil)
    }

    @Test("mounted volume roots are protected")
    func volumeRoots() {
        #expect(ProtectedPaths.reason(for: "/Volumes/External") == .mountedVolume)
        #expect(ProtectedPaths.reason(for: "/Volumes/External SSD") == .mountedVolume)
        #expect(ProtectedPaths.reason(for: "/System/Volumes/Data") == .systemVolume)
    }

    @Test("contents of an external volume are not protected")
    func volumeContentsNotProtected() {
        #expect(ProtectedPaths.reason(for: "/Volumes/External/Movies") == nil)
        #expect(ProtectedPaths.reason(for: "/Volumes/External SSD/backups/2025.dmg") == nil)
    }

    @Test("trailing slashes do not bypass protection", arguments: [
        "/System/", "/System///", "/usr/", "/Users/alice/",
    ])
    func trailingSlashes(path: String) {
        #expect(ProtectedPaths.isProtected(path))
    }

    @Test("non-standardized paths are standardized before matching")
    func standardization() {
        #expect(ProtectedPaths.reason(for: "/System/../System") == .systemFolder)
        #expect(ProtectedPaths.reason(for: "/usr/./local/..") == .systemFolder)
        #expect(ProtectedPaths.reason(for: "/Users//Shared") == .userAccount)
        #expect(ProtectedPaths.reason(for: home + "/Downloads/..") == .homeFolder)
        #expect(ProtectedPaths.reason(for: "/private/tmp") == .systemFolder)
    }

    @Test("deep unrelated paths are not protected")
    func deepPathsNotProtected() {
        #expect(ProtectedPaths.reason(for: "/usr/local/bin/tool") == nil)
        #expect(ProtectedPaths.reason(for: "/Applications/SomeApp.app") == nil)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectedPathsTests-\(UUID().uuidString)").path
        #expect(ProtectedPaths.reason(for: tmp) == nil)
    }
}
