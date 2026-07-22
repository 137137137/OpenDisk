#if canImport(Sparkle)
import AppKit

// Website (direct-download) build only, like SoftwareUpdater.swift: the Mac App
// Store installs into /Applications itself, so this file compiles out of the
// MAS target along with Sparkle.
//
// Why this exists: when a notarized app is launched straight from ~/Downloads,
// Gatekeeper "translocates" it — runs it from a randomized read-only mount.
// Sparkle cannot update a translocated app, so auto-update silently breaks for
// every user who skips the drag-to-Applications step. Offering the move on
// first launch fixes that.
enum MoveToApplications {
    private static let suppressionKey = "move_to_applications_suppressed"

    /// Offers to move the app into an Applications folder when it's running
    /// from somewhere else (typically ~/Downloads). Returns `true` when the
    /// move was performed and a relaunch is underway — the caller should skip
    /// any further startup prompts.
    @MainActor
    static func promptIfNeeded() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        // The on-disk location to move: if we're translocated, Bundle.main
        // points inside the read-only mount, not at the real app in Downloads.
        let sourceURL = translocationOriginal(of: bundleURL) ?? bundleURL

        guard !isInApplicationsFolder(sourceURL) else { return false }
        guard !UserDefaults.standard.bool(forKey: suppressionKey) else { return false }

        let alert = NSAlert()
        alert.messageText = "Move OpenDisk to your Applications folder?"
        alert.informativeText = "OpenDisk works best from the Applications folder — automatic updates require it. It will move itself and reopen."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressionKey)
        }
        guard response == .alertFirstButtonReturn else { return false }

        guard let destination = performMove(from: sourceURL) else {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Couldn't Move OpenDisk"
            failure.informativeText = "Please quit OpenDisk and drag it into the Applications folder yourself."
            failure.runModal()
            return false
        }
        relaunch(at: destination)
        return true
    }

    private static func isInApplicationsFolder(_ url: URL) -> Bool {
        // Covers /Applications, ~/Applications, and subfolders of either.
        url.deletingLastPathComponent().path.range(
            of: #"(^|/)Applications(/|$)"#, options: .regularExpression
        ) != nil
    }

    /// Moves (or, when the volume differs, copies) the app bundle into
    /// /Applications, falling back to ~/Applications when /Applications isn't
    /// writable (non-admin user). Returns the destination on success.
    private static func performMove(from sourceURL: URL) -> URL? {
        let fm = FileManager.default
        var applicationsDirs = [URL(fileURLWithPath: "/Applications")]
        if let userApps = fm.urls(for: .applicationDirectory, in: .userDomainMask).first {
            applicationsDirs.append(userApps)
        }

        for dir in applicationsDirs {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard fm.isWritableFile(atPath: dir.path) else { continue }
            let destination = dir.appendingPathComponent(sourceURL.lastPathComponent)
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.trashItem(at: destination, resultingItemURL: nil)
                }
                do {
                    try fm.moveItem(at: sourceURL, to: destination)
                } catch {
                    // Cross-volume, or the source is read-only (translocation
                    // edge cases): copy instead and trash the original.
                    try fm.copyItem(at: sourceURL, to: destination)
                    try? fm.trashItem(at: sourceURL, resultingItemURL: nil)
                }
                stripQuarantine(at: destination)
                return destination
            } catch {
                continue
            }
        }
        return nil
    }

    /// A programmatic move does not clear Gatekeeper's translocation trigger
    /// the way a user's Finder drag does — the quarantine attribute must go,
    /// or the freshly moved copy can be translocated right back.
    private static func stripQuarantine(at url: URL) {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    private static func relaunch(at url: URL) {
        // `open` from a detached shell outlives this process, so the new copy
        // starts cleanly after we exit.
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "sleep 0.3; /usr/bin/open \"$0\"", url.path]
        try? relauncher.run()
        NSApp.terminate(nil)
    }

    /// Resolves the real on-disk app URL when running translocated. Uses the
    /// SecTranslocate* functions (present since 10.12 but not in the public
    /// headers, hence dlsym — the same approach LetsMove uses).
    private static func translocationOriginal(of url: URL) -> URL? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(handle) }

        typealias IsTranslocatedFn = @convention(c) (
            CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutableRawPointer?
        ) -> Bool
        typealias OriginalPathFn = @convention(c) (
            CFURL, UnsafeMutableRawPointer?
        ) -> Unmanaged<CFURL>?

        guard let isSym = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else {
            return nil
        }
        var translocated: DarwinBoolean = false
        let isTranslocated = unsafeBitCast(isSym, to: IsTranslocatedFn.self)
        guard isTranslocated(url as CFURL, &translocated, nil), translocated.boolValue else {
            return nil
        }
        let originalPath = unsafeBitCast(origSym, to: OriginalPathFn.self)
        return originalPath(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}
#endif
