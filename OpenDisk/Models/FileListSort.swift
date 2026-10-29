import Foundation

enum FileListSortField: Equatable {
    case name
    case size
    case column(FileListColumn)

    /// Text sorts A to Z first; sizes and dates show the largest and newest first.
    var startsAscending: Bool {
        switch self {
        case .name, .column(.kind), .column(.owner): true
        case .size, .column: false
        }
    }
}

struct FileListSort: Equatable {
    var field: FileListSortField = .size
    var ascending = false

    /// Clicking the current column reverses it; another column starts in its natural order.
    mutating func select(_ newField: FileListSortField) {
        if field == newField {
            ascending.toggle()
        } else {
            field = newField
            ascending = newField.startsAscending
        }
    }

    /// Sorting by a column the user turned off would look random, so it falls back to size.
    func resolved(visibleColumns: [FileListColumn]) -> FileListSort {
        guard case .column(let column) = field, !visibleColumns.contains(column) else { return self }
        return FileListSort()
    }

    @MainActor
    func sorted(
        _ items: [FolderItem],
        metadata: (String) -> FileMetadata?
    ) -> [FolderItem] {
        switch field {
        case .name:
            return items.sorted { ordered($0.name.localizedStandardCompare($1.name)) }
        case .size:
            return items.sorted { ascending ? $0.size < $1.size : $0.size > $1.size }
        case .column(.kind):
            return items.sorted {
                ordered(FileKind.description(for: $0).localizedStandardCompare(FileKind.description(for: $1)))
            }
        case .column(.owner):
            return sortedByOwner(items, metadata: metadata)
        case .column(let column):
            return sortedByDate(items, column: column, metadata: metadata)
        }
    }

    private func ordered(_ result: ComparisonResult) -> Bool {
        ascending ? result == .orderedAscending : result == .orderedDescending
    }

    /// Items without a known owner always go last, whatever the direction.
    private func sortedByOwner(
        _ items: [FolderItem],
        metadata: (String) -> FileMetadata?
    ) -> [FolderItem] {
        let owners = Dictionary(
            items.map { ($0.path, metadata($0.path)?.ownerName) },
            uniquingKeysWith: { first, _ in first }
        )
        return items.sorted { lhs, rhs in
            switch (owners[lhs.path] ?? nil, owners[rhs.path] ?? nil) {
            case let (left?, right?) where left != right: ordered(left.localizedStandardCompare(right))
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.size > rhs.size
            }
        }
    }

    /// Items without a known date always go last, whatever the direction.
    private func sortedByDate(
        _ items: [FolderItem],
        column: FileListColumn,
        metadata: (String) -> FileMetadata?
    ) -> [FolderItem] {
        let dates = Dictionary(
            items.map { ($0.path, metadata($0.path)?.date(for: column)) },
            uniquingKeysWith: { first, _ in first }
        )
        return items.sorted { lhs, rhs in
            switch (dates[lhs.path] ?? nil, dates[rhs.path] ?? nil) {
            case let (left?, right?): ascending ? left < right : left > right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.size > rhs.size
            }
        }
    }
}
