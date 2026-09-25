#if canImport(Sparkle)
import AppKit

enum MoveToApplications {
    private static let suppressionKey = "move_to_applications_suppressed"
    private static let relaunchAttemptKey = "translocation_relaunch_attempted"

    @MainActor
    static func promptIfNeeded() -> Bool {
        #if DEBUG
        return false
        #else
        let bundleURL = Bundle.main.bundleURL
        let sourceURL = translocationOriginal(of: bundleURL) ?? bundleURL

        guard !sourceURL.path.contains("/DerivedData/") else { return false }
        if isInApplicationsFolder(sourceURL) {
            guard sourceURL != bundleURL else {
                UserDefaults.standard.removeObject(forKey: relaunchAttemptKey)
                return false
            }
            guard !UserDefaults.standard.bool(forKey: relaunchAttemptKey) else { return false }
            UserDefaults.standard.set(true, forKey: relaunchAttemptKey)
            guard stripQuarantine(at: sourceURL) else { return false }
            relaunch(at: sourceURL)
            return true
        }
        guard !UserDefaults.standard.bool(forKey: suppressionKey) else { return false }

        let alert = NSAlert()
        alert.messageText = "Move OpenDisk to your Applications folder?"
        alert.informativeText = "OpenDisk works best from the Applications folder, and automatic updates require it. It will move itself and reopen."
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
        #endif
    }

    private static func isInApplicationsFolder(_ url: URL) -> Bool {
        url.deletingLastPathComponent().path.range(
            of: #"(^|/)Applications(/|$)"#, options: .regularExpression
        ) != nil
    }

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
                    try fm.copyItem(at: sourceURL, to: destination)
                    try? fm.trashItem(at: sourceURL, resultingItemURL: nil)
                }
                _ = stripQuarantine(at: destination)
                return destination
            } catch {
                continue
            }
        }
        return nil
    }

    @discardableResult
    private static func stripQuarantine(at url: URL) -> Bool {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", url.path]
        do {
            try xattr.run()
        } catch {
            return false
        }
        xattr.waitUntilExit()
        return getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) < 0
    }

    @MainActor
    private static func relaunch(at url: URL) {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        relauncher.arguments = [
            "-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\"",
            url.path,
        ]
        try? relauncher.run()
        NSApp.terminate(nil)
    }

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
