import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum FileColumns {
    static let spacing: CGFloat = 10
    static let icon: CGFloat = 20
    static let size: CGFloat = 76
    static let bar: CGFloat = 48
    static let kind: CGFloat = 140
    static let inset: CGFloat = 8
    static let rowHeight: CGFloat = 28
    static let detailMinWidth: CGFloat = 600
}

struct ListScale: Equatable {
    static let fontSizes: [CGFloat] = [11, 12, 13, 15, 17, 20]
    static let defaultLevel = 2
    static let defaultsKey = "list_text_size_level"

    let level: Int

    init(level: Int) {
        self.level = min(max(level, 0), Self.fontSizes.count - 1)
    }

    var fontSize: CGFloat { Self.fontSizes[level] }
    var headerFontSize: CGFloat { max(10, fontSize - 2) }
    var icon: CGFloat { scaled(FileColumns.icon) }
    var rowHeight: CGFloat { scaled(FileColumns.rowHeight) }

    func scaled(_ base: CGFloat) -> CGFloat {
        (base * fontSize / Self.fontSizes[Self.defaultLevel]).rounded()
    }
}

extension EnvironmentValues {
    @Entry var listScale = ListScale(level: ListScale.defaultLevel)
}

@MainActor
enum FileKind {
    private static var cache: [String: String] = [:]

    static func description(for item: FolderItem) -> String {
        if item.path == HiddenSpaceInfo.sentinelPath { return "Purgeable" }
        if item.path.hasPrefix("::") { return item.isDirectory ? "Folder" : "—" }
        let ext = (item.name as NSString).pathExtension.lowercased()
        let key = (item.isDirectory ? "d:" : "f:") + ext
        if let cached = cache[key] { return cached }
        let resolved = resolve(ext: ext, isDirectory: item.isDirectory)
        cache[key] = resolved
        return resolved
    }

    static func isPackage(_ item: FolderItem) -> Bool {
        guard item.isDirectory, !item.path.hasPrefix("::") else { return false }
        let ext = (item.name as NSString).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext, conformingTo: .directory)
        else { return false }
        return type.conforms(to: .package)
    }

    private static func resolve(ext: String, isDirectory: Bool) -> String {
        guard !ext.isEmpty else { return isDirectory ? "Folder" : "Document" }
        let type = isDirectory
            ? UTType(filenameExtension: ext, conformingTo: .directory)
            : UTType(filenameExtension: ext)
        guard let type, !type.isDynamic, let description = type.localizedDescription else {
            return isDirectory ? "Folder" : "Document"
        }
        if isDirectory && !type.conforms(to: .package) { return "Folder" }
        return description.prefix(1).uppercased() + description.dropFirst()
    }
}

struct FolderRowView: View {
    let item: FolderItem
    var index: Int = 0
    var locationDetail: String? = nil
    var isSelected: Bool = false
    var showsDetailColumns: Bool = true
    var selectionFiles: [CollectedFile] = []
    var sizeFraction: Double? = nil
    var onQuickLook: ((FolderItem) -> Void)? = nil
    let onSelect: () -> Void
    let onOpen: () -> Void

    @Environment(Collector.self) private var collector
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.listScale) private var scale
    @State private var resolvedIcon: NSImage?

    private var isSynthetic: Bool { item.path.hasPrefix("::") }
    private var fileURL: URL { URL(fileURLWithPath: item.path) }
    private var isEmphasized: Bool { isSelected && controlActiveState != .inactive }

    var body: some View {
        if isSynthetic && item.path != HiddenSpaceInfo.sentinelPath {
            row
        } else {
            row.fileDrag { _ in
                dragFiles
            } onBegin: { _ in
                collector.flagDraggedProtected(draggedProtectedReason)
            } onEnd: { _ in
                collector.flagDraggedProtected(nil)
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

    private var primaryStyle: AnyShapeStyle {
        isEmphasized ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary)
    }

    private var secondaryStyle: AnyShapeStyle {
        isEmphasized ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary)
    }

    private var tertiaryStyle: AnyShapeStyle {
        isEmphasized ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary)
    }

    private var row: some View {
        HStack(spacing: FileColumns.spacing) {
            icon
                .frame(width: scale.icon, height: scale.icon)

            HStack(spacing: 6) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(primaryStyle)
                if let locationDetail {
                    Text(locationDetail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(tertiaryStyle)
                        .layoutPriority(-1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if item.sizeIsKnown {
                    Text(item.formattedSize)
                        .monospacedDigit()
                        .foregroundStyle(secondaryStyle)
                } else {
                    Text("--")
                        .foregroundStyle(tertiaryStyle)
                }
            }
            .lineLimit(1)
            .frame(width: scale.scaled(FileColumns.size), alignment: .trailing)

            sizeBar
                .frame(width: scale.scaled(FileColumns.bar))

            if showsDetailColumns {
                Text(FileKind.description(for: item))
                    .lineLimit(1)
                    .foregroundStyle(secondaryStyle)
                    .frame(width: scale.scaled(FileColumns.kind), alignment: .leading)
            }
        }
        .font(.system(size: scale.fontSize))
        .padding(.horizontal, FileColumns.inset)
        .frame(height: scale.rowHeight)
        .background { rowBackground }
        .padding(.horizontal, FileColumns.inset)
        .contentShape(Rectangle())
        .task(id: item.path) {
            guard !isSynthetic, FileIcon.cached(for: item.path) == nil else { return }
            await FileIcon.warm(item.path)
            resolvedIcon = FileIcon.cached(for: item.path)
        }
        .onTapGesture(count: 2, perform: onOpen)
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .contextMenu { menuContent }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onOpen() }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        if isSelected {
            shape.fill(Color(nsColor: isEmphasized
                ? .selectedContentBackgroundColor
                : .unemphasizedSelectedContentBackgroundColor))
        } else if index.isMultiple(of: 2) == false {
            shape.fill(Color(nsColor: NSColor.alternatingContentBackgroundColors[1]))
        }
    }

    @ViewBuilder
    private var sizeBar: some View {
        if let sizeFraction, sizeFraction > 0, item.sizeIsKnown {
            Capsule(style: .continuous)
                .fill(isEmphasized ? AnyShapeStyle(Color.white.opacity(0.3)) : AnyShapeStyle(.quaternary))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule(style: .continuous)
                            .fill(isEmphasized ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint))
                            .frame(width: max(3, proxy.size.width * min(1, sizeFraction)))
                    }
                }
        } else {
            Color.clear.frame(height: 4)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if isSynthetic {
            if item.isDirectory {
                Image(nsImage: FileIcon.folder)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "sparkles")
                    .foregroundStyle(isEmphasized ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint))
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
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        if !isSynthetic {
            Button {
                onOpen()
            } label: {
                Label(item.isDirectory ? "Open" : "Quick Look", systemImage: item.isDirectory ? "folder" : "eye")
            }

            Divider()

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

            if item.isDirectory, let onQuickLook {
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
