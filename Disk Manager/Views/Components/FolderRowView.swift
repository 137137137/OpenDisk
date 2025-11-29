import SwiftUI
import AppKit

struct FolderRowView: View {
    let item: FolderItem
    let onTap: () -> Void

    var body: some View {
        HStack {
            Label {
                HStack {
                    Text(item.name)
                        .lineLimit(1)

                    Spacer()

                    Text(item.formattedSize)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: item.isDirectory ? "folder" : "doc")
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(item.isDirectory ? 1 : 0)
                .padding(.trailing, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
    }
}

