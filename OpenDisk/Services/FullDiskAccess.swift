import AppKit
import Foundation
import OSLog

enum FullDiskAccess {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenDisk",
        category: "FullDiskAccess"
    )

    static var isGranted: Bool {
        let home = NSHomeDirectory()
        let directories = [
            home + "/Library/Containers/com.apple.stocks",
            home + "/Library/Safari",
            home + "/Library/Mail",
            home + "/Library/Messages",
        ]
        let files = [
            "/Library/Preferences/com.apple.TimeMachine.plist",
        ]

        var probed = 0
        var readable = 0
        for path in directories where FileManager.default.fileExists(atPath: path) {
            probed += 1
            if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil {
                readable += 1
            } else {
                log.debug("Full Disk Access probe failed (cannot list \(path))")
            }
        }
        for path in files where FileManager.default.fileExists(atPath: path) {
            probed += 1
            if let handle = FileHandle(forReadingAtPath: path) {
                readable += 1
                try? handle.close()
            } else {
                log.debug("Full Disk Access probe failed (cannot open \(path))")
            }
        }
        return probed > 0 && readable == probed
    }

    @MainActor
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    static func openSystemSettings() {
        _ = isGranted
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )!
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func promptIfNotGranted(title: String, message: String) {
        guard !promptSuppressed, !isGranted else { return }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.icon = NSApp.applicationIconImage
        alert.showsSuppressionButton = true
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            promptSuppressed = true
        }
        if response == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    static func resetPromptSuppression() {
        promptSuppressed = false
    }

    private static var promptSuppressed: Bool {
        get { UserDefaults.standard.bool(forKey: "fda_suppressed") }
        set { UserDefaults.standard.set(newValue, forKey: "fda_suppressed") }
    }
}
