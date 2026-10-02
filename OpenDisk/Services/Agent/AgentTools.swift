import Foundation

/// Read-only tools over a finished scan and its history. Every AI route (API providers,
/// Apple's on-device model, the MCP server) calls these; none of them can change the disk.
struct AgentTools: Sendable {
    let scan: ScanResult
    var redact: Bool = true
    var home: String = UserHome.path
    var historyBase: URL? = nil
    /// Receives a step-by-step account of the analysis for the "Show More" activity log.
    var onEvent: (@Sendable (AgentEvent) -> Void)? = nil

    func log(_ kind: AgentEvent.Kind, _ text: String, detail: String? = nil) {
        onEvent?(AgentEvent(kind: kind, text: text, detail: detail))
    }

    struct Spec: Sendable {
        let name: String
        let description: String
        /// JSON Schema for the arguments.
        let schema: String

        var schemaObject: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(schema.utf8))) as? [String: Any] ?? [:]
        }
    }

    static let proposeName = "propose"

    static let specs: [Spec] = [
        Spec(name: "overview",
             description: "Scan root, total size, free space, the largest folders, and when it was last scanned.",
             schema: #"{"type":"object","properties":{}}"#),
        Spec(name: "list_children",
             description: "Largest items directly inside a folder.",
             schema: #"{"type":"object","properties":{"path":{"type":"string"},"limit":{"type":"integer","description":"Default 30, max 100"}},"required":["path"]}"#),
        Spec(name: "largest_files",
             description: "Largest individual files (100 MB or more), optionally under a folder.",
             schema: #"{"type":"object","properties":{"under":{"type":"string"},"limit":{"type":"integer","description":"Default 30, max 100"}}}"#),
        Spec(name: "known_reclaimable",
             description: "Known caches, build folders and dependency folders found in this scan, with sizes.",
             schema: #"{"type":"object","properties":{}}"#),
        Spec(name: "growth_since",
             description: "Folders that grew or shrank most since a previous scan about `days` ago.",
             schema: #"{"type":"object","properties":{"days":{"type":"integer","description":"Default 30"}}}"#),
        Spec(name: "check_path",
             description: "Whether a path exists in the scan, its size, whether it is protected, and OpenDisk's minimum risk for it.",
             schema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#),
    ]

    static let proposeSpec = Spec(
        name: proposeName,
        description: "Add or update cleanup suggestions (matched by path). Call as often as needed; set done to true on the last call.",
        schema: #"{"type":"object","properties":{"suggestions":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string"},"category":{"type":"string","description":"Short label, e.g. Build cache"},"risk":{"type":"string","enum":["low","medium","high"]},"rationale":{"type":"string","description":"What it is and what is lost if removed"},"regenerates":{"type":"boolean"},"howToRemove":{"type":"string","description":"Preferred removal method, e.g. a cleanup command"}},"required":["path","category","risk","rationale","regenerates"]}},"done":{"type":"boolean","description":"True when you have nothing more to add"}},"required":["suggestions"]}"#
    )

    /// Runs a tool by name. Errors come back as JSON so the model can recover.
    func call(_ name: String, arguments: Data) -> String {
        let args = (try? JSONSerialization.jsonObject(with: arguments.isEmpty ? Data("{}".utf8) : arguments)) as? [String: Any] ?? [:]
        func int(_ key: String, _ fallback: Int, max upper: Int = 100) -> Int {
            min(upper, max(1, (args[key] as? Int) ?? (args[key] as? Double).map(Int.init) ?? fallback))
        }
        let value: Any
        switch name {
        case "overview": value = overview()
        case "list_children": value = listChildren(args["path"] as? String ?? "", limit: int("limit", 30))
        case "largest_files": value = largestFiles(under: args["under"] as? String, limit: int("limit", 30))
        case "known_reclaimable": value = knownReclaimable().map { [
            "path": show($0.path), "size": format($0.size),
            "kind": $0.name, "regenerates": $0.regenerates,
        ] }
        case "growth_since": value = growthSince(days: int("days", 30, max: 3_650))
        case "check_path": value = checkPath(args["path"] as? String ?? "")
        default: value = ["error": "Unknown tool \(name)."]
        }
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let output = String(decoding: data, as: UTF8.self)
        if onEvent != nil {
            let shownArgs = args.isEmpty ? "none" : String(decoding: arguments, as: UTF8.self)
            log(.tool, Self.describe(name, args, show: show), detail: """
            Tool: \(name)
            Arguments: \(shownArgs)

            Result sent to the model (\(output.count) characters):
            \(output.count > 4_000 ? output.prefix(4_000) + "…" : output)
            """)
        }
        return output
    }

    private static func describe(_ name: String, _ args: [String: Any], show: (String) -> String) -> String {
        let path = (args["path"] as? String).map(show)
        switch name {
        case "overview": return "Reading the scan overview"
        case "list_children": return "Looking inside \(path ?? "a folder")"
        case "largest_files": return "Finding the largest files" + ((args["under"] as? String).map { " in \(show($0))" } ?? "")
        case "known_reclaimable": return "Checking known caches and build folders"
        case "growth_since": return "Comparing with a scan from about \(args["days"] as? Int ?? 30) days ago"
        case "check_path": return "Checking \(path ?? "a path")"
        default: return "Called unknown tool \(name)"
        }
    }

    // MARK: - Tools

    func overview() -> [String: Any] {
        let tree = scan.tree
        let digest = tree.digest(rootPath: scan.rootPath, maxDepth: 3)
        let top = digest.entries.filter { $0.depth > 0 && $0.isDir }
            .sorted { $0.size > $1.size }.prefix(25)
            .map { ["path": show($0.path), "size": format($0.size)] }
        var result: [String: Any] = [
            "root": show(scan.rootPath),
            "total": format(tree.size(of: FileTree.rootID)),
            "largestFolders": Array(top),
        ]
        if let volume = DeviceMonitor.volumeCapacity(ofPath: scan.rootPath) {
            result["volumeTotal"] = format(volume.total)
            result["volumeAvailable"] = format(volume.available)
        }
        if let last = ScanHistory.list(root: scan.rootPath, base: historyBase).dropFirst().first {
            result["previousScan"] = last.date.formatted(.iso8601)
        }
        return result
    }

    func listChildren(_ rawPath: String, limit: Int) -> [String: Any] {
        let path = expand(rawPath)
        guard let node = scan.tree.nodeID(forPath: path, rootPath: scan.rootPath) else {
            return ["error": "\(rawPath) is not in the scan."]
        }
        let tree = scan.tree
        let children = tree.childrenSortedForDisplay(of: node)
        let shown = children.prefix(limit).map { child -> [String: Any] in
            var item: [String: Any] = [
                "name": tree.name(of: child), "size": format(tree.size(of: child)), "isDir": tree.isDirectory(child),
            ]
            if tree.isDirectory(child) { item["items"] = tree.childCount(of: child) }
            return item
        }
        return [
            "path": show(path), "size": format(tree.size(of: node)),
            "children": Array(shown), "omitted": max(0, children.count - limit),
        ]
    }

    func largestFiles(under rawPath: String?, limit: Int) -> [[String: Any]] {
        let tree = scan.tree
        let prefix = rawPath.map { expand($0).directoryPrefix }
        return tree.reachableFiles(allocatedAtLeast: 100 << 20)
            .map { (id: $0, path: tree.path(of: $0)) }
            .filter { prefix == nil || $0.path.hasPrefix(prefix!) }
            .sorted { tree.size(of: $0.id) > tree.size(of: $1.id) }
            .prefix(limit)
            .map { ["path": show($0.path), "size": format(tree.size(of: $0.id))] }
    }

    struct Reclaimable: Sendable {
        let name: String
        let path: String
        let size: Int64
        let regenerates: Bool
    }

    /// Dependency and build folders recognised by name anywhere in the scan.
    static let regenerableFolderNames: [String: String] = [
        "node_modules": "npm dependencies",
        ".venv": "Python virtual environment",
        "venv": "Python virtual environment",
        "Pods": "CocoaPods dependencies",
        "DerivedData": "Xcode build products",
        ".next": "Next.js build cache",
        ".turbo": "Turborepo cache",
        ".parcel-cache": "Parcel cache",
        ".gradle": "Gradle cache",
    ]

    func knownReclaimable() -> [Reclaimable] {
        let tree = scan.tree
        var found: [Reclaimable] = CleanableCacheCatalog.locations.compactMap { location in
            guard let node = tree.nodeID(forPath: location.path, rootPath: scan.rootPath) else { return nil }
            let size = tree.size(of: node)
            return size > 0 ? Reclaimable(name: location.name, path: location.path, size: size, regenerates: location.name != "Trash") : nil
        }
        let catalogPaths = found.map(\.path)
        // The digest already prunes folders under 10 MB, which keeps this cheap.
        for entry in tree.digest(rootPath: scan.rootPath).entries where entry.isDir {
            let name = (entry.path as NSString).lastPathComponent
            guard let kind = Self.regenerableFolderNames[name],
                  !catalogPaths.contains(where: { entry.path == $0 || entry.path.hasPrefix($0 + "/") }),
                  !found.contains(where: { entry.path.hasPrefix($0.path + "/") }) else { continue }
            found.append(Reclaimable(name: kind, path: entry.path, size: entry.size, regenerates: true))
        }
        return found.sorted { $0.size > $1.size }
    }

    func growthSince(days: Int) -> [String: Any] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let items = ScanHistory.list(root: scan.rootPath, base: historyBase)
        guard let item = items.first(where: { $0.date <= cutoff }) ?? items.last,
              let old = ScanHistory.load(item) else {
            return ["error": "No earlier scan of this location is saved yet."]
        }
        let current = scan.tree.digest(rootPath: scan.rootPath)
        let changes = ScanDigest.mostSpecific(current.diff(from: old)).prefix(30).map { change -> [String: Any] in
            ["path": show(change.path), "change": ByteFormatter.formatSignedFileSize(change.delta),
             "status": change.oldSize == nil ? "new" : change.newSize == nil ? "gone or below 10 MB" : "changed"]
        }
        return [
            "since": item.date.formatted(.iso8601),
            "totalChange": ByteFormatter.formatSignedFileSize(current.totalBytes - old.totalBytes),
            "changes": Array(changes),
        ]
    }

    func checkPath(_ rawPath: String) -> [String: Any] {
        let path = expand(rawPath)
        var result: [String: Any] = ["path": show(path)]
        if let reason = ProtectedPaths.reason(for: path) { result["protected"] = "It \(reason)." }
        guard let node = scan.tree.nodeID(forPath: path, rootPath: scan.rootPath) else {
            result["inScan"] = false
            return result
        }
        let (risk, why) = SuggestionValidator.ruleRisk(for: path, node: node, in: scan.tree, home: home)
        result["inScan"] = true
        result["size"] = format(scan.tree.size(of: node))
        result["isDir"] = scan.tree.isDirectory(node)
        result["minimumRisk"] = risk.rawValue
        if let why { result["riskReason"] = why }
        return result
    }

    // MARK: - Helpers

    func validate(_ suggestions: [Suggestion], checkDisk: Bool = true) -> SuggestionReport {
        SuggestionValidator.validate(suggestions, in: scan, home: home, checkDisk: checkDisk)
    }

    struct Proposal: Decodable {
        var suggestions: [Suggestion]
        var done: Bool?
    }

    static func decodeProposal(_ data: Data) throws -> Proposal {
        try JSONDecoder().decode(Proposal.self, from: data)
    }

    /// What the model gets back from `propose`, so it can correct rejected items.
    func feedback(for suggestions: [Suggestion]) -> String {
        let report = validate(suggestions)
        var lines = ["Accepted \(report.accepted.count) of \(suggestions.count)."]
        for item in report.accepted where item.riskRaisedReason != nil {
            lines.append("Risk raised to \(item.risk.rawValue) for \(show(item.path)): \(item.riskRaisedReason!)")
        }
        for item in report.rejected { lines.append("Rejected \(show(item.path)): \(item.reason)") }
        return lines.joined(separator: "\n")
    }

    /// Context sent up front so the model doesn't spend turns fetching it.
    func briefing() -> String {
        var parts = [
            "Scan overview:\n" + call("overview", arguments: Data()),
            "Known caches and regenerable folders:\n" + call("known_reclaimable", arguments: Data()),
        ]
        if ScanHistory.list(root: scan.rootPath, base: historyBase).count > 1 {
            parts.append("Growth since an earlier scan:\n" + call("growth_since", arguments: Data()))
        }
        return parts.joined(separator: "\n\n")
    }

    private func expand(_ path: String) -> String { SuggestionValidator.expand(path, home: home) }

    func show(_ path: String) -> String {
        redact ? path.abbreviatingHome(home) : path
    }

    private func format(_ bytes: Int64) -> String { ByteFormatter.formatFileSize(bytes) }
}

/// One step of an analysis, shown in the suggestions sheet's activity log.
struct AgentEvent: Sendable, Identifiable {
    enum Kind: Sendable { case status, request, model, tool, done }
    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String
    var detail: String?
}
