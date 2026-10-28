import Foundation

enum HiddenSpaceInfo {
    static let folderName = String(localized: "Purgeable Space")
    static var sentinelPath: String { "::" + folderName }
}

enum FreeSpaceInfo {
    static let name = String(localized: "Free Space")
    static var sentinelPath: String { "::" + name }
    static let defaultsKey = "chart_show_free_space"
}

enum CleanableCacheCatalog {
    struct Location {
        let name: String
        let path: String
    }

    static var locations: [Location] {
        let home = UserHome.path
        return [
            Location(name: String(localized: "Homebrew Cache"), path: home + "/Library/Caches/Homebrew"),
            Location(name: String(localized: "npm Cache"), path: home + "/.npm/_cacache"),
            Location(name: String(localized: "Yarn Cache"), path: home + "/Library/Caches/Yarn"),
            Location(name: String(localized: "pnpm Store"), path: home + "/Library/pnpm/store"),
            Location(name: String(localized: "pip Cache"), path: home + "/Library/Caches/pip"),
            Location(name: String(localized: "Cargo Registry Cache"), path: home + "/.cargo/registry/cache"),
            Location(name: String(localized: "Go Build Cache"), path: home + "/Library/Caches/go-build"),
            Location(name: String(localized: "Go Module Cache"), path: home + "/go/pkg/mod/cache"),
            Location(name: String(localized: "Gradle Cache"), path: home + "/.gradle/caches"),
            Location(name: String(localized: "CocoaPods Cache"), path: home + "/Library/Caches/CocoaPods"),
            Location(name: String(localized: "Composer Cache"), path: home + "/.composer/cache"),
            Location(name: String(localized: "Xcode DerivedData"), path: home + "/Library/Developer/Xcode/DerivedData"),
            Location(name: String(localized: "Xcode iOS DeviceSupport"), path: home + "/Library/Developer/Xcode/iOS DeviceSupport"),
            Location(name: String(localized: "Xcode Archives"), path: home + "/Library/Developer/Xcode/Archives"),
            Location(name: String(localized: "Playwright Browsers"), path: home + "/.cache/ms-playwright"),
            Location(name: String(localized: "Puppeteer Browsers"), path: home + "/.cache/puppeteer"),
            Location(name: String(localized: "Chrome Cache"), path: home + "/Library/Caches/Google/Chrome"),
            Location(name: String(localized: "Safari Cache"), path: home + "/Library/Caches/com.apple.Safari"),
            Location(name: String(localized: "Hugging Face Cache"), path: home + "/.cache/huggingface"),
            Location(name: String(localized: "PyTorch Hub Cache"), path: home + "/.cache/torch"),
            Location(name: String(localized: "User Logs"), path: home + "/Library/Logs"),
            Location(name: String(localized: "Trash"), path: home + "/.Trash"),
            Location(name: String(localized: "System Caches"), path: "/Library/Caches"),
        ]
    }
}
