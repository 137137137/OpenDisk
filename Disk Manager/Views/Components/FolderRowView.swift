import SwiftUI
import AppKit

struct FolderRowView: View {
    let item: FolderItem
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.title3)
                    .foregroundStyle(item.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .fontWeight(item.isDirectory ? .medium : .regular)
                        .lineLimit(1)

                    if item.isDirectory && item.itemCount > 0 {
                        Text("\(item.itemCount) items")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if item.sizeIsKnown {
                    Text(item.formattedSize)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    // Skeleton row: the scan has not sized this entry yet.
                    Text("0.00 MB")
                        .monospacedDigit()
                        .redacted(reason: .placeholder)
                        .foregroundStyle(.tertiary)
                }

                if item.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(item.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
        }
    }
}
