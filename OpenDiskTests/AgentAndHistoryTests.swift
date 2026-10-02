import Foundation
import Testing
@testable import OpenDisk

private let MB: Int64 = 1 << 20

/// A small home-folder tree rooted at the real home path, so the cache catalog matches.
private func homeScan() -> ScanResult {
    let home = UserHome.path
    var tree = FileTree(rootName: home)
    func dir(_ name: String, _ parent: FileTree.NodeID) -> FileTree.NodeID {
        tree.addNode(name: name, parent: parent, size: 0, isDirectory: true)
    }
    func file(_ name: String, _ parent: FileTree.NodeID, _ size: Int64) {
        tree.addNode(name: name, parent: parent, size: size, isDirectory: false)
    }
    let library = dir("Library", FileTree.rootID)
    let xcode = dir("Xcode", dir("Developer", library))
    file("build.o", dir("DerivedData", xcode), 500 * MB)
    file("thesis.pdf", dir("Documents", FileTree.rootID), 40 * MB)
    let app = dir("app", dir("Projects", FileTree.rootID))
    file("HEAD", dir(".git", app), 1 * MB)
    file("lib.js", dir("node_modules", app), 300 * MB)
    let downloads = dir("Downloads", FileTree.rootID)
    file("Installer.dmg", downloads, 800 * MB)
    file("tiny.txt", downloads, 1_000)
    tree.rollUpDirectorySizes()
    return ScanResult(rootPath: home, tree: tree)
}

@Suite("ScanDigest")
struct ScanDigestTests {
    @Test("small items roll up and sizes still add up")
    func rollup() throws {
        let scan = homeScan()
        let digest = scan.tree.digest(rootPath: scan.rootPath)
        let downloads = try #require(digest.entries.first { $0.path.hasSuffix("/Downloads") })
        #expect(downloads.hiddenCount == 1)
        #expect(downloads.hiddenBytes == 1_000)
        #expect(!digest.entries.contains { $0.path.hasSuffix("tiny.txt") })
        #expect(digest.totalBytes == scan.tree.size(of: FileTree.rootID))

        // Every directory's size = listed children + rolled-up remainder.
        for entry in digest.entries where entry.isDir {
            let children = digest.entries.filter {
                $0.depth == entry.depth + 1 && ($0.path as NSString).deletingLastPathComponent == entry.path
            }
            #expect(children.reduce(entry.hiddenBytes) { $0 + $1.size } == entry.size)
        }
    }

    @Test("a tree rebuilt from a digest keeps paths and totals")
    func treeFromDigest() throws {
        let scan = homeScan()
        let digest = scan.tree.digest(rootPath: scan.rootPath)
        let rebuilt = FileTree(digest: digest)
        #expect(rebuilt.size(of: FileTree.rootID) == digest.totalBytes)
        let dmg = try #require(rebuilt.nodeID(forPath: scan.rootPath + "/Downloads/Installer.dmg", rootPath: scan.rootPath))
        #expect(rebuilt.size(of: dmg) == 800 * MB)
        #expect(rebuilt.digest(rootPath: scan.rootPath, date: digest.date).totalBytes == digest.totalBytes)
    }

    @Test("JSON roundtrip and redaction")
    func roundtripAndRedaction() throws {
        let scan = homeScan()
        let digest = scan.tree.digest(rootPath: scan.rootPath, date: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try ScanDigest.decode(digest.jsonData()) == digest)

        let redacted = digest.redacted()
        #expect(redacted.rootPath == "~")
        #expect(redacted.entries.allSatisfy { !$0.path.contains(UserHome.path) })
        #expect(redacted.markdown().contains("Installer.dmg"))
    }

    @Test("diff reports growth, new and gone paths, most specific first")
    func diff() {
        let old = ScanDigest(rootPath: "/r", date: .distantPast, totalBytes: 100, entries: [
            .init(path: "/r", size: 100, isDir: true, depth: 0),
            .init(path: "/r/a", size: 60, isDir: true, depth: 1),
            .init(path: "/r/a/cache", size: 50, isDir: true, depth: 2),
            .init(path: "/r/old", size: 40, isDir: true, depth: 1),
        ])
        let new = ScanDigest(rootPath: "/r", date: .now, totalBytes: 220, entries: [
            .init(path: "/r", size: 220, isDir: true, depth: 0),
            .init(path: "/r/a", size: 160, isDir: true, depth: 1),
            .init(path: "/r/a/cache", size: 150, isDir: true, depth: 2),
            .init(path: "/r/new", size: 60, isDir: true, depth: 1),
        ])
        let changes = new.diff(from: old)
        #expect(changes.map(\.path) == ["/r/a", "/r/a/cache", "/r/new", "/r/old"])
        #expect(changes.first { $0.path == "/r/old" }?.delta == -40)

        let specific = ScanDigest.mostSpecific(changes).map(\.path)
        #expect(!specific.contains("/r/a"))
        #expect(specific.contains("/r/a/cache"))
    }
}

@Suite("ScanHistory")
struct ScanHistoryTests {
    private func digest(_ date: Date, total: Int64) -> ScanDigest {
        ScanDigest(rootPath: "/r", date: date, totalBytes: total, entries: [.init(path: "/r", size: total, isDir: true, depth: 0)])
    }

    @Test("save, list newest first, skip near-duplicates, load")
    func saveAndList() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(ScanHistory.save(digest(t0, total: 1_000_000), base: base))
        #expect(!ScanHistory.save(digest(t0 + 60, total: 1_000_100), base: base), "same size within 10 min is skipped")
        #expect(ScanHistory.save(digest(t0 + 120, total: 2_000_000), base: base))

        let items = ScanHistory.list(root: "/r", base: base)
        #expect(items.map(\.totalBytes) == [2_000_000, 1_000_000])
        #expect(ScanHistory.load(items[1])?.totalBytes == 1_000_000)
    }

    @Test("prune keeps the last 30 days and one snapshot per older week")
    func prune() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Two snapshots a day for 60 days.
        for halfDay in 0..<120 {
            let date = now - Double(halfDay) * 43_200
            ScanHistory.save(digest(date, total: Int64(1_000_000 + halfDay * 10_000)), base: base)
        }
        ScanHistory.prune(root: "/r", base: base, now: now)
        let items = ScanHistory.list(root: "/r", base: base)
        let recent = items.filter { now.timeIntervalSince($0.date) < 30 * 86_400 }
        #expect(recent.count == 60)
        #expect(items.count - recent.count <= 6)
    }
}

@Suite("SuggestionValidator")
struct SuggestionValidatorTests {
    private func suggest(_ path: String, _ risk: Risk = .low) -> Suggestion {
        Suggestion(path: path, category: "test", risk: risk, rationale: "", regenerates: true)
    }

    @Test("protected, system, missing and home paths are rejected")
    func rejections() {
        let scan = homeScan()
        let report = SuggestionValidator.validate([
            suggest("~"), suggest("/System/Library/Caches"), suggest("/usr/local"),
            suggest("~/Nope"), suggest("/"), suggest("/Users"),
        ], in: scan, checkDisk: false)
        #expect(report.accepted.isEmpty)
        #expect(report.rejected.count == 6)
    }

    @Test("risk floors: catalog stays low, personal data and repos go high, the rest medium")
    func riskFloors() throws {
        let scan = homeScan()
        let report = SuggestionValidator.validate([
            suggest("~/Library/Developer/Xcode/DerivedData"),
            suggest("~/Documents/thesis.pdf"),
            suggest("~/Projects/app/node_modules"),
            suggest("~/Downloads/Installer.dmg"),
        ], in: scan, checkDisk: false)
        func risk(_ suffix: String) -> Risk? { report.accepted.first { $0.path.hasSuffix(suffix) }?.risk }
        #expect(risk("DerivedData") == .low)
        #expect(risk("thesis.pdf") == .high)
        #expect(risk("node_modules") == .high)
        #expect(risk("Installer.dmg") == .medium)
        #expect(report.accepted.first { $0.path.hasSuffix("thesis.pdf") }?.riskRaisedReason != nil)
    }

    @Test("the model can't lower a risk, sizes come from the scan, nested items are dropped")
    func noLoweringAndSizes() throws {
        let scan = homeScan()
        let report = SuggestionValidator.validate([
            suggest("~/Library/Developer/Xcode/DerivedData", .high),
            suggest("~/Library/Developer/Xcode/DerivedData/build.o"),
        ], in: scan, checkDisk: false)
        let item = try #require(report.accepted.first)
        #expect(report.accepted.count == 1)
        #expect(item.risk == .high)
        #expect(item.size == 500 * MB)
        #expect(report.rejected.contains { $0.reason.hasPrefix("Already covered") })
    }

    @Test("rule provider: catalog stays low, repo folders are raised")
    func ruleProvider() async throws {
        let tools = AgentTools(scan: homeScan())
        let report = tools.validate(tools.knownReclaimable().map(Suggestion.init), checkDisk: false)
        #expect(report.accepted.contains { $0.path.hasSuffix("DerivedData") && $0.risk == .low })
        // node_modules is found by name but sits in a Git repo, so the validator raises it.
        #expect(report.accepted.contains { $0.path.hasSuffix("node_modules") && $0.risk == .high })
    }

    @Test("tool calls return JSON and redact the home folder")
    func toolsJSON() throws {
        let tools = AgentTools(scan: homeScan())
        let output = tools.call("list_children", arguments: Data(#"{"path":"~/Downloads"}"#.utf8))
        #expect(!output.contains(UserHome.path))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect((object["children"] as? [[String: Any]])?.first?["name"] as? String == "Installer.dmg")
        #expect(tools.call("bogus", arguments: Data()).contains("Unknown tool"))
    }
}

@Suite("MCPServer")
struct MCPServerTests {
    @Test("serves saved scans read-only and validates proposals")
    func toolsOverHistory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let scan = homeScan()
        ScanHistory.save(scan.tree.digest(rootPath: scan.rootPath), base: base)
        let server = MCPServer(historyBase: base)

        #expect(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let names = server.toolList().compactMap { $0["name"] as? String }
        #expect(names.contains("list_scans") && names.contains("propose"))
        #expect(!names.contains { $0.contains("delete") || $0.contains("remove") })

        let (scans, _) = server.call("list_scans", arguments: [:])
        #expect(scans.contains(scan.rootPath))

        let (children, failed) = server.call("list_children", arguments: ["path": scan.rootPath + "/Downloads"])
        #expect(!failed)
        #expect(children.contains("Installer.dmg"))

        let (checked, _) = server.call("propose", arguments: ["suggestions": [
            ["path": "/System", "category": "x", "risk": "low", "rationale": "", "regenerates": false],
        ]])
        #expect(checked.contains("rejected"))
        #expect(checked.contains("macOS system folder"))
    }
}
