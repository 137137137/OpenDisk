import SwiftUI
import AppKit

/// One row in the results list. Uses the real Finder icon for the file/folder
/// (via NSWorkspace) so the list reads as native, and is draggable into the
/// Collector for deletion.
struct FolderRowView: View {
    let item: FolderItem
    let onTap: () -> Void

    @Environment(Collector.self) private var collector
    @State private var isHovered = false

    /// Synthetic rows ("::"-prefixed, e.g. Purgeable Space) have no on-disk
    /// location, so they can't be dragged, collected, or revealed.
    private var isSynthetic: Bool { item.path.hasPrefix("::") }
    private var fileURL: URL { URL(fileURLWithPath: item.path) }

    var body: some View {
        // The "Purgeable Space" row is draggable — dropping it collects its
        // real, deletable cache folders (expanded on drop, sizes match).
        // Any other synthetic row (there are none now) stays non-draggable.
        if isSynthetic && item.path != HiddenSpaceInfo.sentinelPath {
            row
        } else {
            // Not a Button: a Button's press gesture swallows the drag on
            // macOS, so the row would never become draggable.
            //
            // Protected items (Users, system folders, …) can still be *picked
            // up*, but the moment the drag begins we tell the Collector why it
            // can't be collected — so it says "no" immediately, before the
            // user even reaches the drop zone — and clear it when the drag ends.
            row.draggable(CollectedFile(item)) {
                dragPreview
                    .onAppear {
                        collector.flagDraggedProtected(
                            ProtectedPaths.reason(for: item.path).map { "“\(item.name)” \($0)" }
                        )
                    }
                    .onDisappear { collector.flagDraggedProtected(nil) }
            }
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
        // No per-row .onHover here: it fires (and animates) on every row that
        // slides under the cursor while scrolling, which makes fast scrolling
        // of a big list stutter. Row highlight is handled cheaply below.
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // simultaneousGesture (not onTapGesture) so the tap doesn't
        // exclusively capture the gesture and starve `.draggable`.
        .simultaneousGesture(TapGesture().onEnded { onTap() })
        .contextMenu { menuContent }
    }

    /// Real Finder icon for on-disk items; a symbol for synthetic rows.
    @ViewBuilder
    private var icon: some View {
        if isSynthetic {
            if item.isDirectory {
                // Synthetic folders (Purgeable Space) read as a normal folder.
                Image(nsImage: FileIcon.folder)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 22)
            }
        } else {
            Image(nsImage: FileIcon.icon(for: item.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
        }
    }

    private var dragPreview: some View {
        HStack(spacing: 6) {
            Image(nsImage: isSynthetic ? FileIcon.folder : FileIcon.icon(for: item.path))
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
