import Foundation

enum AppIdentity {
    /// The app's bundle ID, also when running as the embedded `opendisk-mcp` helper
    /// (`OpenDisk.app/Contents/Helpers/opendisk-mcp`), so both share cache and history folders.
    static let bundleID: String = {
        if Bundle.main.bundleURL.pathExtension == "app", let id = Bundle.main.bundleIdentifier {
            return id
        }
        let app = Bundle.main.executableURL?
            .deletingLastPathComponent()   // Helpers
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // OpenDisk.app
        if let app, app.pathExtension == "app", let id = Bundle(url: app)?.bundleIdentifier {
            return id
        }
        return Bundle.main.bundleIdentifier ?? "OpenDisk"
    }()
}
