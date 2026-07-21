import SwiftUI
import AppKit

/// One row in the results list. Uses the real Finder icon for the file/folder
/// (via NSWorkspace) so the list reads as native, and is draggable into the
/// Collector for deletion.
struct FolderRowView: View {
    let item: FolderItem
    /// Containing-folder string shown under the name (search results,
    /// where hits come from anywhere in the tree). Nil in directory
    /// listings, where location is implied by the breadcrumb.
    var locationDetail: String? = nil
    /// Whether this row is part of the current multi-selection.
    var isSelected: Bool = false
    /// Every currently selected item as a collector payload. A drag (or a
    /// context-menu collect) from a selected row carries all of them.
    var selectionFiles: [CollectedFile] = []
    /// This item's size as a fraction of the largest sibling, driving the
    /// faint proportional bar. Nil (e.g. in search results) hides the bar.
    var sizeFraction: Double? = nil
    let onTap: () -> Void

    @Environment(Collector.self) private var collector
    @State private var isHovered = false
    /// The row's real Finder icon once resolved off-main; until then the
    /// row draws a type icon so scrolling never blocks on IconServices.
    @State private var resolvedIcon: NSImage?

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
            row.draggable(CollectedFileGroup(files: dragFiles)) {
                dragPreview
                    .onAppear {
                        collector.flagDraggedProtected(draggedProtectedReason)
                    }
                    .onDisappear { collector.flagDraggedProtected(nil) }
            }
        }
    }

    /// What a drag from this row carries: the whole selection when the row
    /// is part of it, otherwise just the row itself (Finder's rule).
    private var dragFiles: [CollectedFile] {
        isSelected && selectionFiles.count > 1 ? selectionFiles : [CollectedFile(item)]
    }

    private var draggedProtectedReason: String? {
        for file in dragFiles {
            if let reason = ProtectedPaths.reason(for: file.path) {
                return "“\(file.name)” \(reason)"
            }
        }
        return nil
    }

    private var row: some View {
        HStack(spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .fontWeight(item.isDirectory ? .medium : .regular)
                    .lineLimit(1)

                if let locationDetail {
                    Text(locationDetail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if item.isDirectory && item.itemCount > 0 {
                    Text("\(item.itemCount) items")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            // Faint proportional bar (relative to the largest sibling): a
            // subtle read of how big each item is, only for sized entries.
            if let sizeFraction, sizeFraction > 0, item.sizeIsKnown {
                Capsule(style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 46, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(.secondary)
                            .frame(width: max(3, 46 * min(1, sizeFraction)), height: 4)
                    }
            }

            // Right-aligned size, Finder-style; "--" while a folder is still
            // being tallied (instead of a loading-bar skeleton).
            Group {
                if item.sizeIsKnown {
                    Text(item.formattedSize)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("--")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 66, alignment: .trailing)

            // Disclosure chevron for navigable folders; files reserve the same
            // width (invisible) so the bar and size column stay aligned across
            // every row.
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(item.isDirectory ? 1 : 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        // No per-row .onHover here: it fires (and animates) on every row that
        // slides under the cursor while scrolling, which makes fast scrolling
        // of a big list stutter. Row highlight is handled cheaply below.
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // Resolve the real Finder icon off the main thread; the row shows
        // a type icon meanwhile. A synchronous per-row IconServices call
        // here was what made fast scrolling through fresh (search) results
        // stutter.
        .task(id: item.path) {
            // Usually a no-op: the list prewarms icons in display order,
            // so by the time a row scrolls in its icon is already cached
            // and the body drew it directly — no state churn mid-scroll.
            guard !isSynthetic, FileIcon.cached(for: item.path) == nil else { return }
            await FileIcon.warm(item.path)
            resolvedIcon = FileIcon.cached(for: item.path)
        }
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
            // Cache, then the freshly resolved icon, then a no-I/O type
            // icon — never a blocking per-path lookup during scrolling.
            Image(nsImage: resolvedIcon
                ?? FileIcon.cached(for: item.path)
                ?? FileIcon.typeIcon(
                    forPathExtension: (item.name as NSString).pathExtension,
                    isDirectory: item.isDirectory
                ))
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
            if dragFiles.count > 1 {
                Text("\(dragFiles.count) items").lineLimit(1)
                Text(ByteFormatter.formatFileSize(dragFiles.reduce(0) { $0 + $1.size }))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text(item.name).lineLimit(1)
                Text(item.formattedSize)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
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
                Label("Add to Collector", systemImage: "trash")
            }
            // macOS-critical locations can't be deleted.
            .disabled(ProtectedPaths.isProtected(item.path))

            if isSelected && selectionFiles.count > 1 {
                Button {
                    collector.add(selectionFiles.filter {
                        ProtectedPaths.reason(for: $0.path) == nil
                    })
                } label: {
                    Label(
                        "Add \(selectionFiles.count) Selected to Collector",
                        systemImage: "trash"
                    )
                }
            }

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
