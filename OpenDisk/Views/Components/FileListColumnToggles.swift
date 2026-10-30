import SwiftUI

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
