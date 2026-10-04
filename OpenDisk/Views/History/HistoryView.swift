import AppKit
import SwiftUI

/// Lists saved snapshots for the scanned root and compares one against the current scan.
struct HistoryView: View {
    let analyzer: DiskAnalyzer
    let rootPath: String
    var onNavigate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [ScanHistory.Item] = []
    @State private var selection: ScanHistory.Item?
    @State private var comparison: Comparison?
    @State private var isLoading = false

    struct Comparison {
        var from: ScanDigest
        var to: ScanDigest
        var changes: [ScanDigest.Change]
        var totalDelta: Int64 { to.totalBytes - from.totalBytes }
    }

    var body: some View {
        NavigationSplitView {
            List(items, selection: $selection) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                    Text(ByteFormatter.formatFileSize(item.totalBytes))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(item)
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No History Yet", systemImage: "clock",
                        description: Text("Each completed scan of this location is saved here.")
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        }
        .task {
            let root = rootPath
            items = await Task.detached { ScanHistory.list(root: root) }.value
            selection = items.dropFirst().first ?? items.first
        }
        .task(id: selection) { await compare() }
    }

    @ViewBuilder
    private var detail: some View {
        if isLoading {
            ProgressView()
        } else if let comparison {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Since \(comparison.from.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.headline)
                    Text("\(ByteFormatter.formatSignedFileSize(comparison.totalDelta)) · \(ByteFormatter.formatFileSize(comparison.from.totalBytes)) → \(ByteFormatter.formatFileSize(comparison.to.totalBytes))")
                        .foregroundStyle(comparison.totalDelta > 0 ? .orange : .green)
                    Text("Folders under \(ByteFormatter.formatFileSize(ScanDigest.defaultMinSize)) aren't tracked, so small changes are not listed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
                Divider()
                List(comparison.changes.prefix(200)) { change in
                    Button { open(change) } label: { row(change) }
                        .buttonStyle(.plain)
                }
            }
        } else {
            ContentUnavailableView("Select a Snapshot", systemImage: "clock.arrow.circlepath")
        }
    }

    private func row(_ change: ScanDigest.Change) -> some View {
        HStack {
            Image(systemName: change.isDir ? "folder" : "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text((change.path as NSString).lastPathComponent)
                Text(change.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if change.oldSize == nil { badge("New") }
            if change.newSize == nil { badge("Gone") }
            Text(ByteFormatter.formatSignedFileSize(change.delta))
                .monospacedDigit()
                .foregroundStyle(change.delta > 0 ? .orange : .green)
        }
        .contentShape(Rectangle())
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    private func open(_ change: ScanDigest.Change) {
        let folder = change.isDir ? change.path : (change.path as NSString).deletingLastPathComponent
        if change.newSize != nil, FileManager.default.fileExists(atPath: folder) {
            onNavigate(folder)
            dismiss()
        }
    }

    /// Compares the selected snapshot with the current scan, or with the newest snapshot
    /// when the selected one is the newest and nothing newer is loaded.
    private func compare() async {
        guard let selection else { comparison = nil; return }
        isLoading = true
        defer { isLoading = false }
        let current = await analyzer.currentDigest()
        let newest = items.first
        comparison = await Task.detached {
            guard let from = ScanHistory.load(selection) else { return nil }
            let to: ScanDigest? = current?.rootPath == from.rootPath
                ? current
                : (newest == selection ? nil : newest.flatMap(ScanHistory.load))
            guard let to else { return nil }
            return Comparison(from: from, to: to, changes: ScanDigest.mostSpecific(to.diff(from: from)))
        }.value
    }
}
