import Foundation
import Testing
@testable import OpenDisk

@Suite("File list sorting")
@MainActor
struct FileListSortTests {
    private let small = FolderItem(name: "b.txt", path: "/t/b.txt", size: 10, isDirectory: false, itemCount: 0)
    private let large = FolderItem(name: "a.zip", path: "/t/a.zip", size: 900, isDirectory: false, itemCount: 0)
    private let medium = FolderItem(name: "c", path: "/t/c", size: 500, isDirectory: true, itemCount: 3)

    private func metadata(
        modified: [String: Date] = [:],
        owners: [String: String] = [:]
    ) -> (String) -> FileMetadata? {
        { path in
            FileMetadata(
                modificationDate: modified[path],
                creationDate: nil,
                lastOpenedDate: nil,
                posixPermissions: nil,
                ownerName: owners[path]
            )
        }
    }

    @Test("starts sorted by size, largest first")
    func defaultSort() {
        let sorted = FileListSort().sorted([small, large, medium]) { _ in nil }
        #expect(sorted.map(\.name) == ["a.zip", "c", "b.txt"])
    }

    @Test("selecting a column picks its natural direction, selecting it again reverses")
    func selecting() {
        var sort = FileListSort()
        sort.select(.name)
        #expect(sort == FileListSort(field: .name, ascending: true))
        sort.select(.column(.modified))
        #expect(sort == FileListSort(field: .column(.modified), ascending: false))
        sort.select(.column(.modified))
        #expect(sort.ascending)
    }

    @Test("dates sort newest first and items without a date go last")
    func dates() {
        let modified = [
            small.path: Date(timeIntervalSince1970: 100),
            large.path: Date(timeIntervalSince1970: 300),
        ]
        var sort = FileListSort(field: .column(.modified), ascending: false)
        let newestFirst = sort.sorted([medium, small, large], metadata: metadata(modified: modified))
        #expect(newestFirst.map(\.name) == ["a.zip", "b.txt", "c"])

        sort.ascending = true
        let oldestFirst = sort.sorted([medium, small, large], metadata: metadata(modified: modified))
        #expect(oldestFirst.map(\.name) == ["b.txt", "a.zip", "c"])
    }

    @Test("owners sort A to Z and items without an owner go last")
    func owners() {
        let owners = [small.path: "root", large.path: "alice"]
        var sort = FileListSort()
        sort.select(.column(.owner))
        #expect(sort.ascending)
        let aToZ = sort.sorted([medium, small, large], metadata: metadata(owners: owners))
        #expect(aToZ.map(\.name) == ["a.zip", "b.txt", "c"])

        sort.select(.column(.owner))
        let zToA = sort.sorted([medium, small, large], metadata: metadata(owners: owners))
        #expect(zToA.map(\.name) == ["b.txt", "a.zip", "c"])
    }

    @Test("sorting by a hidden column falls back to size")
    func hiddenColumn() {
        let sort = FileListSort(field: .column(.created), ascending: true)
        #expect(sort.resolved(visibleColumns: [.kind, .modified]) == FileListSort())
        #expect(sort.resolved(visibleColumns: [.created]) == sort)
        #expect(FileListSort(field: .name).resolved(visibleColumns: []).field == .name)
    }
}
