import SwiftUI
import AppKit

struct FolderRowView: View {
    let item: FolderItem
    var locationDetail: String? = nil
    var isSelected: Bool = false
    var selectionFiles: [CollectedFile] = []
    var sizeFraction: Double? = nil
    var onQuickLook: ((FolderItem) -> Void)? = nil
    let onTap: () -> Void

    @Environment(Collector.self) private var collector
    @State private var isHovered = false
    @State private var resolvedIcon: NSImage?

    private var isSynthetic: Bool { item.path.hasPrefix("::") }
    private var fileURL: URL { URL(fileURLWithPath: item.path) }

    var body: some View {
        if isSynthetic && item.path != HiddenSpaceInfo.sentinelPath {
            row
        } else {
            row.draggable(CollectedFileGroup(files: dragFiles)) {
                dragPreview
                    .onAppear {
                        collector.flagDraggedProtected(draggedProtectedReason)
                    }
                    .onDisappear { collector.flagDraggedProtected(nil) }
            }
        }
    }

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

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(item.isDirectory ? 1 : 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
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
        .task(id: item.path) {
            guard !isSynthetic, FileIcon.cached(for: item.path) == nil else { return }
            await FileIcon.warm(item.path)
            resolvedIcon = FileIcon.cached(for: item.path)
        }
        .simultaneousGesture(TapGesture().onEnded { onTap() })
        .contextMenu { menuContent }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }

    @ViewBuilder
    private var icon: some View {
        if isSynthetic {
            if item.isDirectory {
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

            if let onQuickLook {
                Button {
                    onQuickLook(item)
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
            }

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
