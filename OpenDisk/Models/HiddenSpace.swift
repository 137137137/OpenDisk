import Foundation

enum HiddenSpaceInfo {
    static let folderName = "Purgeable Space"
    static var sentinelPath: String { "::" + folderName }
}

enum CleanableCacheCatalog {
    struct Location {
        let name: String
        let path: String
    }

    static var locations: [Location] {
        let home = UserHome.path
        return [
            Location(name: "Homebrew Cache", path: home + "/Library/Caches/Homebrew"),
            Location(name: "npm Cache", path: home + "/.npm/_cacache"),
            Location(name: "Yarn Cache", path: home + "/Library/Caches/Yarn"),
            Location(name: "pnpm Store", path: home + "/Library/pnpm/store"),
            Location(name: "pip Cache", path: home + "/Library/Caches/pip"),
            Location(name: "Cargo Registry Cache", path: home + "/.cargo/registry/cache"),
            Location(name: "Go Build Cache", path: home + "/Library/Caches/go-build"),
            Location(name: "Go Module Cache", path: home + "/go/pkg/mod/cache"),
            Location(name: "Gradle Cache", path: home + "/.gradle/caches"),
            Location(name: "CocoaPods Cache", path: home + "/Library/Caches/CocoaPods"),
            Location(name: "Composer Cache", path: home + "/.composer/cache"),
            Location(name: "Xcode DerivedData", path: home + "/Library/Developer/Xcode/DerivedData"),
            Location(name: "Xcode iOS DeviceSupport", path: home + "/Library/Developer/Xcode/iOS DeviceSupport"),
            Location(name: "Xcode Archives", path: home + "/Library/Developer/Xcode/Archives"),
            Location(name: "Playwright Browsers", path: home + "/.cache/ms-playwright"),
            Location(name: "Puppeteer Browsers", path: home + "/.cache/puppeteer"),
            Location(name: "Chrome Cache", path: home + "/Library/Caches/Google/Chrome"),
            Location(name: "Safari Cache", path: home + "/Library/Caches/com.apple.Safari"),
            Location(name: "Hugging Face Cache", path: home + "/.cache/huggingface"),
            Location(name: "PyTorch Hub Cache", path: home + "/.cache/torch"),
            Location(name: "User Logs", path: home + "/Library/Logs"),
            Location(name: "Trash", path: home + "/.Trash"),
            Location(name: "System Caches", path: "/Library/Caches"),
        ]
    }
}
