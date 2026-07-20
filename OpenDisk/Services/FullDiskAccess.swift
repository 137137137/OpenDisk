import AppKit
import Foundation
import OSLog

/// Full Disk Access helpers: probe, prompt, and a jump to System Settings.
///
/// Derived from the open-source `FullDiskAccess` helper by Mahdi Bchatnia
/// (github.com/inket/FullDiskAccess, MIT), trimmed to the API this app
/// uses and to its deployment target.
enum FullDiskAccess {

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenDisk",
        category: "FullDiskAccess"
    )

    /// Whether Full Disk Access is currently granted.
    ///
    /// Probes a TCC-protected app container; reading it also registers the
    /// app in the Full Disk Access list of System Settings. (Probing a
    /// world-readable path like `/Library/Application Support` does NOT
    /// work — it succeeds without FDA.)
    static var isGranted: Bool {
        let probePath = NSString(
            string: "~/Library/Containers/com.apple.stocks"
        ).expandingTildeInPath
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: probePath)
            return true
        } catch {
            log.debug("Full Disk Access is not granted (cannot read probe path)")
            return false
        }
    }

    /// Opens System Settings on Privacy & Security > Full Disk Access.
    static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )!
        NSWorkspace.shared.open(url)
    }

    /// Shows a one-time alert offering to open System Settings when Full
    /// Disk Access is missing. Honors the user's "do not ask again" choice.
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

    /// Undoes a "do not ask again" choice.
    static func resetPromptSuppression() {
        promptSuppressed = false
    }

    private static var promptSuppressed: Bool {
        get { UserDefaults.standard.bool(forKey: "fda_suppressed") }
        set { UserDefaults.standard.set(newValue, forKey: "fda_suppressed") }
    }
}
