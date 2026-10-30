import AppKit
import Darwin
import Foundation
import Security

enum RelatedFiles {
    enum Kind: String, Codable, Sendable {
        case applicationSupport, caches, preferences, container, groupContainer
        case savedState, logs, webData, cookies, scripts, launchAgent

        var label: String {
            switch self {
            case .applicationSupport: String(localized: "Application Support")
            case .caches: String(localized: "Caches")
            case .preferences: String(localized: "Preferences")
            case .container: String(localized: "Container")
            case .groupContainer: String(localized: "Shared Container")
            case .savedState: String(localized: "Saved State")
            case .logs: String(localized: "Logs")
            case .webData: String(localized: "Web Data")
            case .cookies: String(localized: "Cookies")
            case .scripts: String(localized: "Scripts")
            case .launchAgent: String(localized: "Launch Agent")
            }
        }

        var mayHoldUserData: Bool {
            switch self {
            case .applicationSupport, .container, .groupContainer: true
            default: false
            }
        }
    }

    struct Candidate: Sendable {
        let path: String
        let isDirectory: Bool
        let kind: Kind
    }

    static func isAppBundle(_ path: String, isDirectory: Bool) -> Bool {
        isDirectory && path.hasSuffix(".app") && !path.hasPrefix("/System/")
    }

    static func bundleIdentifier(ofAppAt path: String) -> String? {
        infoPlist(ofBundleAt: path)?["CFBundleIdentifier"] as? String
    }

    static func discover(appAt appPath: String) -> [Candidate] {
        guard let info = infoPlist(ofBundleAt: appPath),
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
              !isInstalledElsewhere(bundleID: bundleID, besides: appPath)
        else { return [] }

        let fileName = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let ids = ownedIdentifiers(mainID: bundleID, appPath: appPath)
        let names = Set([fileName, info["CFBundleName"] as? String, info["CFBundleDisplayName"] as? String]
            .compactMap { $0 }
            .filter { $0.count >= 3 && !$0.contains("/") && !$0.hasPrefix(".") })

        let library = UserHome.path + "/Library"
        var found: [String: Candidate] = [:]
        func consider(_ path: String, _ kind: Kind) {
            guard found[path] == nil, let isDirectory = deletableItem(at: path) else { return }
            found[path] = Candidate(path: path, isDirectory: isDirectory, kind: kind)
        }

        for id in ids {
            consider("\(library)/Application Support/\(id)", .applicationSupport)
            consider("\(library)/Caches/\(id)", .caches)
            consider("\(library)/Logs/\(id)", .logs)
            consider("\(library)/Preferences/\(id).plist", .preferences)
            consider("\(library)/Containers/\(id)", .container)
            consider("\(library)/Application Scripts/\(id)", .scripts)
            consider("\(library)/Saved Application State/\(id).savedState", .savedState)
            consider("\(library)/HTTPStorages/\(id)", .webData)
            consider("\(library)/HTTPStorages/\(id).binarycookies", .cookies)
            consider("\(library)/WebKit/\(id)", .webData)
            consider("\(library)/Cookies/\(id).binarycookies", .cookies)
            if let host = hostUUID {
                consider("\(library)/Preferences/ByHost/\(id).\(host).plist", .preferences)
            }
        }

        for name in names {
            consider("\(library)/Application Support/\(name)", .applicationSupport)
            consider("\(library)/Caches/\(name)", .caches)
            consider("\(library)/Logs/\(name)", .logs)
        }

        for group in appGroups(ofAppAt: appPath, ownedIDs: ids) {
            consider("\(library)/Group Containers/\(group)", .groupContainer)
        }

        for agent in launchAgents(in: "\(library)/LaunchAgents", ownedIDs: ids, appPath: appPath) {
            consider(agent, .launchAgent)
        }

        return found.values
            .filter { !ProtectedPaths.isProtected($0.path) }
            .sorted { $0.path < $1.path }
    }

    static func measure(_ paths: [String]) async -> [String: Int64] {
        await withTaskGroup(of: (String, Int64).self) { group in
            var sizes: [String: Int64] = [:]
            sizes.reserveCapacity(paths.count)
            for path in paths {
                group.addTask { (path, await allocatedSize(of: path)) }
            }
            for await (path, size) in group { sizes[path] = size }
            return sizes
        }
    }

    private static func infoPlist(ofBundleAt path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist") else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func deletableItem(at path: String) -> Bool? {
        var info = stat()
        guard lstat(path, &info) == 0,
              FileManager.default.isDeletableFile(atPath: path) else { return nil }
        return info.st_mode & S_IFMT == S_IFDIR
    }

    private static func isInstalledElsewhere(bundleID: String, besides appPath: String) -> Bool {
        let own = (appPath as NSString).standardizingPath
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).contains { url in
            let path = url.standardizedFileURL.path
            return path != own
                && !path.hasPrefix(own + "/")
                && !path.contains("/.Trash/")
                && FileManager.default.fileExists(atPath: path)
        }
    }

    private static func ownedIdentifiers(mainID: String, appPath: String) -> [String] {
        var ids = [mainID]
        let contents = appPath + "/Contents"
        let nested = ["PlugIns", "XPCServices", "Frameworks", "Library/LoginItems", "Library/LaunchServices"]
        for folder in nested {
            let directory = "\(contents)/\(folder)"
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for child in children where child.hasSuffix(".app") || child.hasSuffix(".appex") || child.hasSuffix(".xpc") {
                if let id = infoPlist(ofBundleAt: "\(directory)/\(child)")?["CFBundleIdentifier"] as? String,
                   id.hasPrefix(mainID + "."), !ids.contains(id) {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    private static func appGroups(ofAppAt appPath: String, ownedIDs: [String]) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: appPath) as CFURL, [], &code) == errSecSuccess,
              let code else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any],
              let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        let team = signing[kSecCodeInfoTeamIdentifier as String] as? String
        let owned = Set(ownedIDs)
        return groups.filter { group in
            if group.hasPrefix("group."), owned.contains(String(group.dropFirst(6))) { return true }
            if let team, group.hasPrefix(team + "."), owned.contains(String(group.dropFirst(team.count + 1))) { return true }
            return false
        }
    }

    private static func launchAgents(in directory: String, ownedIDs: [String], appPath: String) -> [String] {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        let owned = Set(ownedIDs)
        let bundlePrefix = (appPath as NSString).standardizingPath + "/"
        return children.compactMap { child -> String? in
            guard child.hasSuffix(".plist") else { return nil }
            let path = "\(directory)/\(child)"
            if owned.contains(String(child.dropLast(6))) { return path }
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            else { return nil }
            let associated: [String] = (plist["AssociatedBundleIdentifiers"] as? [String])
                ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
            if associated.contains(where: owned.contains) { return path }
            let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
            if let program, program.hasPrefix(bundlePrefix) { return path }
            return nil
        }
    }

    private static let hostUUID: String? = {
        var uuid = [UInt8](repeating: 0, count: 16)
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        guard gethostuuid(&uuid, &timeout) == 0 else { return nil }
        return NSUUID(uuidBytes: uuid).uuidString
    }()

    private static func allocatedSize(of path: String) async -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        guard info.st_mode & S_IFMT == S_IFDIR else { return Int64(info.st_blocks) * 512 }

        let devices: Set<dev_t> = [info.st_dev]
        guard case .contents(let contents, _) = BulkDirectoryReader().read(directoryAt: path, allowedDevices: devices)
        else { return 0 }
        let files = contents.files.reduce(Int64(0)) { $0 + $1.size }
        return await withTaskGroup(of: Int64.self) { group in
            for name in contents.subdirectoryNames {
                let subdirectory = path + "/" + name
                group.addTask { walk(subdirectory, devices: devices) }
            }
            return await group.reduce(files, +)
        }
    }

    private static func walk(_ root: String, devices: Set<dev_t>) -> Int64 {
        let reader = BulkDirectoryReader()
        var total: Int64 = 0
        var pending = [root]
        while let directory = pending.popLast() {
            guard case .contents(let contents, _) = reader.read(directoryAt: directory, allowedDevices: devices) else { continue }
            for file in contents.files { total += file.size }
            for name in contents.subdirectoryNames { pending.append(directory + "/" + name) }
        }
        return total
    }
}
