import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import OpenDisk

@MainActor
@Suite("File drag pasteboard", .serialized)
struct FileDragTests {
    private func makeFixture() throws -> (root: URL, files: [CollectedFile]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDragTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("report final (1).pdf")
        try Data(count: 12).write(to: fileURL)
        let folderURL = root.appendingPathComponent("Folder – ünïcode", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let files = [
            CollectedFile(path: fileURL.path, name: fileURL.lastPathComponent, size: 12, isDirectory: false),
            CollectedFile(path: folderURL.path, name: folderURL.lastPathComponent, size: 0, isDirectory: true),
        ]
        return (root, files)
    }

    private func write(_ files: [CollectedFile]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("FileDragTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects(files.map { FileDragItem($0) }))
        return pasteboard
    }

    @Test("every dragged file is a real file URL, in order, like a Finder drag")
    func fileURLsForExternalApps() throws {
        let (root, files) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = write(files)
        defer { pasteboard.releaseGlobally() }

        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        #expect(urls.map(\.standardizedFileURL.path) == files.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let allFileURLs = urls.allSatisfy(\.isFileURL)
        #expect(allFileURLs)

        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == files.count)
        for (item, file) in zip(items, files) {
            let raw = try #require(item.string(forType: .fileURL))
            #expect(URL(string: raw)?.path == file.path)
            #expect(item.types == [.fileURL])
        }
    }

    @Test("no JSON or data representation leaks to other apps")
    func noJSONOrFilePromise() throws {
        let (root, files) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = write(files)
        defer { pasteboard.releaseGlobally() }

        let allTypes = (pasteboard.pasteboardItems ?? []).flatMap(\.types).map(\.rawValue)
        #expect(!allTypes.contains(UTType.json.identifier))
        #expect(!allTypes.contains(where: { $0.lowercased().contains("promise") }))
        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) ?? []
        #expect(promises.isEmpty)
        let strings = pasteboard.readObjects(forClasses: [NSString.self]) as? [String] ?? []
        let noJSONText = strings.allSatisfy { !$0.contains("\"path\"") }
        #expect(noJSONText)
    }

    @Test("legacy filename list is available for older drop targets")
    func legacyFilenames() throws {
        let (root, files) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = write(files)
        defer { pasteboard.releaseGlobally() }

        let legacy = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String]
        #expect(legacy == files.map(\.path))
    }

    @Test("exported items carry nothing but the file URL, exactly like a Finder drag")
    func exportedItemsMatchFinder() throws {
        let (root, files) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ours = write(files)
        defer { ours.releaseGlobally() }
        let reference = NSPasteboard(name: NSPasteboard.Name("FileDragTests-ref-\(UUID().uuidString)"))
        defer { reference.releaseGlobally() }
        reference.clearContents()
        #expect(reference.writeObjects(files.map { $0.url as NSURL }))

        let ourTypes = (ours.pasteboardItems ?? []).map(\.types)
        let referenceTypes = (reference.pasteboardItems ?? []).map(\.types)
        #expect(ourTypes == referenceTypes)
        let ourURLs = (ours.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL) }
        let referenceURLs = (reference.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL) }
        #expect(ourURLs == referenceURLs)
    }

    @Test("hidden-space sentinel carries no file URL but still reaches the collector")
    func sentinelHasNoFileURL() throws {
        let sentinel = CollectedFile(
            path: HiddenSpaceInfo.sentinelPath, name: "Hidden", size: 1, isDirectory: false
        )
        let pasteboard = write([sentinel])
        defer { pasteboard.releaseGlobally() }

        let item = try #require(pasteboard.pasteboardItems?.first)
        #expect(item.types == [.collectedFile])
        let data = try #require(item.data(forType: .collectedFile))
        #expect(try JSONDecoder().decode(CollectedFile.self, from: data) == sentinel)
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        #expect(urls.isEmpty)
    }

    @Test("mixed drag keeps real files as URLs and skips only the sentinel")
    func mixedDrag() throws {
        let (root, files) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = CollectedFile(
            path: HiddenSpaceInfo.sentinelPath, name: "Hidden", size: 1, isDirectory: false
        )
        let pasteboard = write([files[0], sentinel, files[1]])
        defer { pasteboard.releaseGlobally() }

        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        #expect(urls.map(\.path) == files.map(\.path))
        #expect(pasteboard.pasteboardItems?.count == 3)
    }

    @Test("other apps get Finder's normal move or copy, never alias or delete")
    func operationMask() {
        let outside = FileDragSource.operationMask(for: .outsideApplication)
        #expect(outside == [.copy, .move, .generic])
        #expect(!outside.contains(.link))
        #expect(!outside.contains(.delete))
        #expect(FileDragSource.operationMask(for: .withinApplication).contains(.copy))
    }

    @Test("collector drag-outs carry no file URL so nothing can copy the file")
    func collectorDragHasNoFileURL() throws {
        let (root, files) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("FileDragTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects(files.map { FileDragItem($0, exportsFileURL: false) }))

        let types = (pasteboard.pasteboardItems ?? []).map(\.types)
        #expect(types == Array(repeating: [.collectedFile], count: files.count))
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) ?? []
        #expect(urls.isEmpty)
    }
}
