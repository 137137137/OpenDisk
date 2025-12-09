import SwiftUI
import AppKit

struct FolderRowView: View {
    let item: FolderItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Label {
                    Text(item.name)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                        .foregroundStyle(item.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }

                Spacer()

                Text(item.formattedSize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                if item.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
    }
}
