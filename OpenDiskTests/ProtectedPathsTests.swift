import Foundation
import Testing
@testable import OpenDisk

/// Contract tests for the pure guard that decides which paths may never be
/// permanently deleted. These test the documented intent — the *real* current
/// user's home is protected — rather than any particular home-lookup API
/// (in a non-sandboxed test runner `NSHomeDirectory()` and `getpwuid` agree).
@Suite("ProtectedPaths")
struct ProtectedPathsTests {

    /// The real current user's home, standardized the same way the guard
    /// normalizes its input.
    private var home: String {
        var h = (NSHomeDirectory() as NSString).standardizingPath
        while h.count > 1 && h.hasSuffix("/") { h.removeLast() }
        return h
    }

    // MARK: - Disk root and system folders

    @Test("the disk root is protected")
    func diskRoot() {
        #expect(ProtectedPaths.reason(for: "/") == "is the disk root and can't be deleted")
        // Extra slashes standardize down to the root.
        #expect(ProtectedPaths.reason(for: "///") == "is the disk root and can't be deleted")
    }

    @Test("macOS system folders are protected", arguments: [
        "/System", "/Library", "/usr", "/bin", "/sbin", "/private",
        "/etc", "/var", "/tmp", "/cores", "/opt", "/dev", "/Network",
        "/Volumes", "/Applications", "/Users",
        "/System/Volumes", "/System/Applications", "/System/Library",
    ])
    func systemFolders(path: String) {
        #expect(ProtectedPaths.reason(for: path) == "is a macOS system folder and can't be deleted")
        #expect(ProtectedPaths.isProtected(path))
    }

    // MARK: - /Users and its direct children

    @Test("direct children of /Users are user account folders", arguments: [
        "/Users/alice", "/Users/somebody-else", "/Users/Shared",
    ])
    func userAccountRoots(path: String) {
        #expect(ProtectedPaths.reason(for: path) == "is a user account folder and can't be deleted")
    }

    @Test("deep paths inside another user's account are not protected")
    func otherUsersDeepPaths() {
        #expect(ProtectedPaths.reason(for: "/Users/alice/Downloads") == nil)
        #expect(ProtectedPaths.reason(for: "/Users/Shared/Movies/big.mov") == nil)
    }

    // MARK: - The current user's home

    @Test("the real user home is protected")
    func homeProtected() {
        #expect(ProtectedPaths.reason(for: home) == "is your home folder and can't be deleted")
        #expect(ProtectedPaths.reason(for: home + "/") == "is your home folder and can't be deleted")
    }

    @Test("the user's ~/Library is protected")
    func homeLibraryProtected() {
        #expect(ProtectedPaths.reason(for: home + "/Library") == "is your Library and can't be deleted")
        #expect(ProtectedPaths.reason(for: home + "/Library/") == "is your Library and can't be deleted")
    }

    @Test("tilde inputs expand to the home folder")
    func tildeExpansion() {
        #expect(ProtectedPaths.reason(for: "~") == "is your home folder and can't be deleted")
        #expect(ProtectedPaths.reason(for: "~/Library") == "is your Library and can't be deleted")
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
        // Only ~/Library itself is guarded, not everything inside it.
        #expect(ProtectedPaths.reason(for: home + "/Library/Caches") == nil)
    }

    // MARK: - Volumes

    @Test("mounted volume roots are protected")
    func volumeRoots() {
        #expect(ProtectedPaths.reason(for: "/Volumes/External") == "is a mounted volume and can't be deleted")
        #expect(ProtectedPaths.reason(for: "/Volumes/External SSD") == "is a mounted volume and can't be deleted")
        #expect(ProtectedPaths.reason(for: "/System/Volumes/Data") == "is a macOS system volume and can't be deleted")
    }

    @Test("contents of an external volume are not protected")
    func volumeContentsNotProtected() {
        #expect(ProtectedPaths.reason(for: "/Volumes/External/Movies") == nil)
        #expect(ProtectedPaths.reason(for: "/Volumes/External SSD/backups/2025.dmg") == nil)
    }

    // MARK: - Normalization of messy inputs

    @Test("trailing slashes do not bypass protection", arguments: [
        "/System/", "/System///", "/usr/", "/Users/alice/",
    ])
    func trailingSlashes(path: String) {
        #expect(ProtectedPaths.isProtected(path))
    }

    @Test("non-standardized paths are standardized before matching")
    func standardization() {
        // ".." and "." components collapse to the protected target.
        #expect(ProtectedPaths.reason(for: "/System/../System") == "is a macOS system folder and can't be deleted")
        #expect(ProtectedPaths.reason(for: "/usr/./local/..") == "is a macOS system folder and can't be deleted")
        #expect(ProtectedPaths.reason(for: "/Users//Shared") == "is a user account folder and can't be deleted")
        #expect(ProtectedPaths.reason(for: home + "/Downloads/..") == "is your home folder and can't be deleted")
        // The "/private" prefix standardizes away (e.g. /private/tmp -> /tmp).
        #expect(ProtectedPaths.reason(for: "/private/tmp") == "is a macOS system folder and can't be deleted")
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
