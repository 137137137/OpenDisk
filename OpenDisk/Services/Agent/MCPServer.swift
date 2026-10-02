import Foundation

/// Minimal MCP server over stdio (`OpenDisk --mcp`), for Claude Desktop, Claude Code and
/// other MCP clients. Serves the saved scan history through the same read-only `AgentTools`
/// the in-app agent uses. There is no tool that changes the disk.
///
/// ponytail: hand-rolled JSON-RPC covering initialize/ping/tools only. Switch to the official
/// modelcontextprotocol/swift-sdk if resources, prompts or other transports are needed.
struct MCPServer {
    var historyBase: URL? = nil

    struct Scan {
        let rootPath: String
        let date: Date
        let item: ScanHistory.Item
    }

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let response = handle(message) { send(response) }
        }
    }

    func handle(_ message: [String: Any]) -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        guard let id = message["id"] else { return nil } // notification
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }

        switch method {
        case "initialize":
            return result([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "opendisk", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"],
                "instructions": AgentPrompt.rules + "\nScans come from OpenDisk's saved history (folders of 10 MB or more). Call `list_scans` first. OpenDisk can't delete anything through this server; tell the user what to remove and how.",
            ])
        case "ping":
            return result([:] as [String: Any])
        case "tools/list":
            return result(["tools": toolList()])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = call(name, arguments: arguments)
            return result(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    // MARK: - Tools

    private static var rootProperty: [String: Any] { [
        "type": "string", "description": "Scan root from list_scans. Defaults to the most recent scan.",
    ] }

    func toolList() -> [[String: Any]] {
        var tools: [[String: Any]] = [[
            "name": "list_scans",
            "description": "Locations OpenDisk has scanned, with the date and size of the latest saved scan.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ]]
        for spec in AgentTools.specs + [AgentTools.proposeSpec] {
            var schema = spec.schemaObject
            var properties = schema["properties"] as? [String: Any] ?? [:]
            properties["root"] = Self.rootProperty
            schema["properties"] = properties
            let description = spec.name == AgentTools.proposeName
                ? "Check cleanup suggestions against OpenDisk's safety rules: drops protected or missing paths, uses real sizes, and raises risk where needed. Returns the checked list."
                : spec.description
            tools.append(["name": spec.name, "description": description, "inputSchema": schema])
        }
        return tools
    }

    func call(_ name: String, arguments: [String: Any]) -> (String, Bool) {
        let scans = availableScans()
        if name == "list_scans" {
            let list = scans.map {
                ["root": $0.rootPath, "scannedAt": $0.date.formatted(.iso8601), "sizeText": ByteFormatter.formatFileSize($0.item.totalBytes)]
            }
            return (json(list.isEmpty ? ["error": "No saved scans yet. Scan a location in OpenDisk first."] : list), false)
        }

        let wanted = (arguments["root"] as? String).map { SuggestionValidator.expand($0) }
        guard let scan = wanted.map({ root in scans.first { $0.rootPath == root } }) ?? scans.first,
              let digest = ScanHistory.load(scan.item) else {
            return (json(["error": wanted == nil ? "No saved scans yet. Scan a location in OpenDisk first." : "No saved scan for that root. Call list_scans."]), true)
        }
        let tools = AgentTools(
            scan: ScanResult(rootPath: digest.rootPath, tree: FileTree(digest: digest)),
            redact: false, historyBase: historyBase
        )

        if name == AgentTools.proposeName {
            let payload = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data()
            guard let suggestions = try? AgentTools.decodeProposal(payload).suggestions else {
                return (json(["error": "Expected {\"suggestions\": [...]} matching the schema."]), true)
            }
            let report = tools.validate(suggestions)
            return (json([
                "scannedAt": scan.date.formatted(.iso8601),
                "accepted": report.accepted.map { [
                    "path": $0.path, "sizeText": ByteFormatter.formatFileSize($0.size), "risk": $0.risk.rawValue,
                    "riskRaisedReason": $0.riskRaisedReason ?? "", "category": $0.suggestion.category,
                    "rationale": $0.suggestion.rationale,
                ] },
                "rejected": report.rejected.map { ["path": $0.path, "reason": $0.reason] },
            ]), false)
        }

        guard AgentTools.specs.contains(where: { $0.name == name }) else {
            return (json(["error": "Unknown tool \(name)."]), true)
        }
        var rest = arguments
        rest["root"] = nil
        let output = tools.call(name, arguments: (try? JSONSerialization.data(withJSONObject: rest)) ?? Data())
        return (output, output.hasPrefix(#"{"error""#))
    }

    /// Newest saved snapshot per scan root, most recent first.
    func availableScans() -> [Scan] {
        guard let historyDir = ScanHistory.rootDirectory(base: historyBase),
              let folders = try? FileManager.default.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: nil)
        else { return [] }
        return folders.compactMap { folder -> Scan? in
            guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
                  let newest = urls.filter({ $0.pathExtension == "json" }).max(by: { $0.lastPathComponent < $1.lastPathComponent }),
                  let digest = (try? Data(contentsOf: newest)).flatMap({ try? ScanDigest.decode($0) }),
                  let item = ScanHistory.list(root: digest.rootPath, base: historyBase).first
            else { return nil }
            return Scan(rootPath: digest.rootPath, date: item.date, item: item)
        }
        .sorted { $0.date > $1.date }
    }

    private func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
