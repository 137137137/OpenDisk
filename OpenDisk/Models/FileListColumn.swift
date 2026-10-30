import CoreGraphics
import Foundation

enum FileListColumn: String, CaseIterable, Identifiable, Sendable {
    case kind
    case modified
    case created
    case lastOpened
    case permissions
    case owner

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kind: String(localized: "Kind")
        case .modified: String(localized: "Modified")
        case .created: String(localized: "Created")
        case .lastOpened: String(localized: "Last Opened")
        case .permissions: String(localized: "Permissions")
        case .owner: String(localized: "Owner")
        }
    }

    private var baseWidth: CGFloat {
        switch self {
        case .kind: FileColumns.kind
        case .modified, .created, .lastOpened: 84
        case .permissions: 80
        case .owner: 90
        }
    }

    func width(scale: ListScale, kindWidth: CGFloat?) -> CGFloat {
        if self == .kind, let kindWidth { return kindWidth }
        return scale.scaled(baseWidth)
    }

    var isDate: Bool {
        self == .modified || self == .created || self == .lastOpened
    }

    var isSortable: Bool { self != .permissions }

    var needsMetadata: Bool { self != .kind }
}

struct FileListColumnSelection: Equatable {
    static let defaultsKey = "visible_file_list_columns"
    static let defaultStoredValue = FileListColumnSelection(columns: [.kind]).storedValue

    let columns: [FileListColumn]

    init(columns: [FileListColumn]) {
        let chosen = Set(columns)
        self.columns = FileListColumn.allCases.filter { chosen.contains($0) }
    }

    init(storedValue: String) {
        let names = storedValue.split(separator: ",").map(String.init)
        self.init(columns: names.compactMap(FileListColumn.init(rawValue:)))
    }

    var storedValue: String {
        columns.map(\.rawValue).joined(separator: ",")
    }

    func contains(_ column: FileListColumn) -> Bool {
        columns.contains(column)
    }

    func setting(_ column: FileListColumn, visible: Bool) -> FileListColumnSelection {
        let others = columns.filter { $0 != column }
        return FileListColumnSelection(columns: visible ? others + [column] : others)
    }
}

enum FileListLayout {
    static let nameMinWidth: CGFloat = 134

    static func columnsThatFit(
        _ columns: [FileListColumn],
        in listWidth: CGFloat,
        scale: ListScale,
        kindWidth: CGFloat
    ) -> [FileListColumn] {
        var remainingWidth = listWidth - alwaysVisibleWidth(scale: scale)
        var fittingColumns: [FileListColumn] = []
        for column in columns {
            remainingWidth -= column.width(scale: scale, kindWidth: kindWidth) + FileColumns.spacing
            guard remainingWidth >= 0 else { break }
            fittingColumns.append(column)
        }
        return fittingColumns
    }

    private static func alwaysVisibleWidth(scale: ListScale) -> CGFloat {
        FileColumns.inset * 4
            + scale.icon
            + scale.scaled(nameMinWidth)
            + scale.scaled(FileColumns.size)
            + scale.scaled(FileColumns.bar)
            + FileColumns.spacing * 3
    }
}
