import SwiftUI

/// One checkbox per optional column; used in the column header's context menu
/// and in the View menu.
struct FileListColumnToggles: View {
    @AppStorage(FileListColumnSelection.defaultsKey)
    private var storedColumns = FileListColumnSelection.defaultStoredValue

    var body: some View {
        ForEach(FileListColumn.allCases) { column in
            Toggle(column.title, isOn: isVisible(column))
        }
    }

    private func isVisible(_ column: FileListColumn) -> Binding<Bool> {
        Binding {
            FileListColumnSelection(storedValue: storedColumns).contains(column)
        } set: { visible in
            storedColumns = FileListColumnSelection(storedValue: storedColumns)
                .setting(column, visible: visible)
                .storedValue
        }
    }
}
