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
        let probes = [
            "/Library/Containers/com.apple.stocks",
            "/Library/Safari",
            "/Library/Mail",
            "/Library/Messages",
        ].map { home + $0 }

        for path in probes where FileManager.default.fileExists(atPath: path) {
            if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil {
                return true
            }
            log.debug("Full Disk Access is not granted (cannot read \(path))")
            return false
        }
        return false
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
