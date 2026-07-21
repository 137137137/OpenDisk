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
    /// Probes several TCC-protected locations that require FDA to read (and
    /// reading them also registers the app in the FDA list of System Settings).
    /// The first probe that *exists* settles it — readable means granted,
    /// unreadable means denied — and a path that isn't present on this Mac is
    /// skipped rather than counted as a denial. (A world-readable path like
    /// `/Library/Application Support` must NOT be used — it succeeds without FDA.)
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

    /// Relaunches the app — Full Disk Access only reaches a *freshly launched*
    /// process, so after the user turns it on we offer to quit and reopen.
    @MainActor
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
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
    /// Main-actor isolated: it builds and runs an `NSAlert` and reads `NSApp`.
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

    /// Undoes a "do not ask again" choice.
    static func resetPromptSuppression() {
        promptSuppressed = false
    }

    private static var promptSuppressed: Bool {
        get { UserDefaults.standard.bool(forKey: "fda_suppressed") }
        set { UserDefaults.standard.set(newValue, forKey: "fda_suppressed") }
    }
}
