import SwiftUI
import AppKit

/// One row in the results list. Uses the real Finder icon for the file/folder
/// (via NSWorkspace) so the list reads as native, and is draggable into the
/// Collector for deletion.
struct FolderRowView: View {
    let item: FolderItem
    let onTap: () -> Void

    @Environment(Collector.self) private var collector

    /// Synthetic rows ("::"-prefixed, e.g. Purgeable Space) have no on-disk
    /// location, so they can't be dragged, collected, or revealed.
    private var isSynthetic: Bool { item.path.hasPrefix("::") }
    private var fileURL: URL { URL(fileURLWithPath: item.path) }

    var body: some View {
        if isSynthetic {
            row
        } else {
            // Not a Button: a Button's press gesture swallows the drag on
            // macOS, so the row would never become draggable.
            row.draggable(CollectedFile(item)) { dragPreview }
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            icon

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
        .hoverHighlight()
        .contentShape(Rectangle())
        // simultaneousGesture (not onTapGesture) so the tap doesn't
        // exclusively capture the gesture and starve `.draggable`.
        .simultaneousGesture(TapGesture().onEnded { onTap() })
        .contextMenu { menuContent }
    }

    /// Real Finder icon for on-disk items; a symbol for synthetic rows.
    @ViewBuilder
    private var icon: some View {
        if isSynthetic {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24, height: 22)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
        }
    }

    private var dragPreview: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(item.name).lineLimit(1)
            Text(item.formattedSize)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var menuContent: some View {
        if !isSynthetic {
            Button {
                collector.add(CollectedFile(item))
            } label: {
                Label("Collect for Deletion", systemImage: "trash")
            }
            // macOS-critical locations can't be deleted.
            .disabled(ProtectedPaths.isProtected(item.path))

            Divider()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
        }
    }
}
