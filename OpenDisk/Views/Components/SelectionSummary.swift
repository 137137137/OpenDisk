import AppKit
import SwiftUI

struct SelectionSummary: View {
    let selected: [FolderItem]
    let folderPath: String
    let folderName: String
    let folderSize: Int64
    let folderItemCount: Int
    let onShowInFinder: () -> Void
    let onCollect: () -> Void

    private var single: FolderItem? { selected.count == 1 ? selected.first : nil }

    private var canCollect: Bool {
        !selected.isEmpty && selected.contains { !ProtectedPaths.isProtected($0.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            details
            if !selected.isEmpty || !folderPath.hasPrefix("::") {
                HStack {
                    Button("Show in Finder", action: onShowInFinder)
                    Spacer(minLength: 8)
                    if !selected.isEmpty {
                        Button("Add to Collector", systemImage: "tray.and.arrow.down", action: onCollect)
                            .buttonStyle(.borderedProminent)
                            .disabled(!canCollect)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            headerIcon
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var headerIcon: some View {
        if selected.count > 1 {
            Image(systemName: "doc.on.doc")
                .font(.title2)
                .foregroundStyle(.secondary)
        } else {
            let path = single?.path ?? folderPath
            Image(nsImage: path.hasPrefix("::") ? FileIcon.folder : FileIcon.icon(for: path))
                .resizable()
                .interpolation(.high)
        }
    }

    private var title: String {
        if let single { return single.name }
        if selected.count > 1 { return "\(selected.count.formatted()) items selected" }
        return folderName
    }

    private var subtitle: String {
        if let single { return FileKind.description(for: single) }
        if selected.count > 1 { return "Selection" }
        return "Current folder"
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            row("Size", ByteFormatter.formatFileSize(totalSize))
            if let count = itemCount {
                row("Items", count.formatted())
            }
            if let location {
                row("Where", location)
            }
        }
        .font(.callout)
    }

    private var totalSize: Int64 {
        selected.isEmpty ? folderSize : selected.reduce(0) { $0 + $1.size }
    }

    private var itemCount: Int? {
        if let single {
            guard single.isDirectory, !FileKind.isPackage(single), single.itemCount > 0 else { return nil }
            return single.itemCount
        }
        if selected.count > 1 { return nil }
        return folderItemCount
    }

    private var location: String? {
        let path = single?.path ?? (selected.isEmpty ? folderPath : nil)
        guard let path, !path.hasPrefix("::") else { return nil }
        return ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
