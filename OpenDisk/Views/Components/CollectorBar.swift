import SwiftUI
import AppKit
import Quartz

extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    static var collectorDrop: Self { .named("collectorDrop") }
}

struct CollectorBar: View {
    let collector: Collector
    var isTargeted: Bool = false
    var onDeleted: (Int64) -> Void

    @State private var phase: Phase = .idle
    @State private var footerHovered = false
    @State private var listHovered = false
    @State private var footerHeight: CGFloat = 0
    @State private var showConfirm = false
    @State private var previewItem: PreviewItem?
    @State private var lastResult: Collector.Result?
    @State private var listVisible = false
    @State private var collapseTask: Task<Void, Never>?

    private enum Phase: Equatable { case idle, deleting, done }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var footerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    private var isCompact: Bool {
        phase == .idle && collector.isEmpty && !collecting && !rejecting
    }

    private var wantsList: Bool {
        phase == .idle && !collector.isEmpty && collector.draggingOut == nil
            && (footerHovered || listHovered || isTargeted)
    }

    private var collecting: Bool {
        isTargeted && collector.draggingOut == nil
    }

    private var rejecting: Bool {
        phase == .idle && collector.draggedProtectedReason != nil
    }

    private var listHeight: CGFloat {
        min(600, CGFloat(collector.count) * 30 + 16)
    }

    var body: some View {
        footerBar
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .collectorDrop)
            } action: { collector.keepZones["footer"] = $0 }
            .onHover { footerHovered = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            .overlay(alignment: .bottom) {
                if listVisible {
                    listPanel
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .collectorDrop)
                        } action: { collector.keepZones["list"] = $0 }
                        .onDisappear { collector.keepZones["list"] = nil }
                        .onHover { listHovered = $0 }
                        .offset(y: -(footerHeight + 8))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .overlay(alignment: .bottom) {
                if let notice = collector.blockedNotice {
                    noticeBanner(notice)
                        .offset(y: -(footerHeight + 8))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .onChange(of: collector.draggingOut == nil) { _, idle in
                if !idle { listHovered = false; footerHovered = false }
            }
            .onChange(of: wantsList) { _, want in
                collapseTask?.cancel()
                if want {
                    listVisible = true
                } else {
                    collapseTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(160))
                        if !Task.isCancelled { listVisible = false }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .animation(.spring(duration: 0.3), value: listVisible)
            .animation(.easeInOut(duration: 0.15), value: collecting)
            .animation(.spring(duration: 0.3), value: collector.count)
            .animation(.spring(duration: 0.3), value: phase)
            .animation(.spring(duration: 0.3), value: collector.blockedNotice)
            .animation(.easeInOut(duration: 0.15), value: rejecting)
            .animation(.snappy(duration: 0.25), value: collector.deletionProgress)
            .sheet(item: $previewItem) { item in
                QuickLookSheet(url: item.url)
            }
            .confirmationDialog(
                "Delete \(collector.count) items?",
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete \(collector.formattedTotal)", role: .destructive) {
                    Task { await performDeletion(.delete) }
                }
                Button("Move to Trash") {
                    Task { await performDeletion(.trash) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deleting is permanent and can’t be undone. Moving to the Trash lets you put items back, but the space isn’t freed until you empty the Trash.")
            }
    }

    private var footerBar: some View {
        PanelContainer {
            footerContent
                .frame(maxWidth: isCompact ? nil : .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .panelBackground(
                    tint: rejecting ? .red : (collecting ? .accentColor : nil),
                    in: footerShape
                )
                .overlay {
                    footerShape.strokeBorder(
                        rejecting ? Color.red : (collecting ? Color.accentColor : .clear),
                        lineWidth: 1.5
                    )
                }
        }
    }

    @ViewBuilder
    private var footerContent: some View {
        if rejecting {
            rejectionView
        } else {
            switch phase {
            case .idle:
                if collector.isEmpty { hintView } else { footerRow }
            case .deleting:  deletingView
            case .done:      doneView
            }
        }
    }

    private var rejectionView: some View {
        HStack(spacing: 8) {
            Image(systemName: "nosign")
            Text(collector.draggedProtectedReason ?? "This item can’t be deleted")
                .lineLimit(3)
        }
        .font(.callout)
        .fontWeight(.semibold)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var footerRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(collector.formattedTotal)
                    .font(.headline)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("\(collector.count) items collected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .fileDrag({ _ in collector.items }, exportsFileURLs: false) { files in
                collector.beginDragOut(files)
            } onEnd: { operation in
                collector.endDragOut(operation: operation)
            }
            Spacer()
            DeleteButton {
                showConfirm = true
            }
            .disabled(collector.isEmpty)
        }
    }

    private var hintView: some View {
        HStack(spacing: 8) {
            Image(systemName: collecting ? "arrow.down.circle.fill" : "arrow.down.circle.dotted")
            Text(collecting ? "Release to collect" : "Drop files to collect")
        }
        .font(.callout)
        .fontWeight(collecting ? .semibold : .medium)
        .foregroundStyle(.primary)
        .frame(maxWidth: collecting ? .infinity : nil)
        .help("Drag files or folders here to stage them for deletion")
        .padding(.vertical, 2)
    }

    private var deletingView: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(deletingTitle)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let progress = collector.deletionProgress {
                        let freed = Text(ByteFormatter.formatFileSize(progress.freedBytes))
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        ((progress.disposal == .trash ? Text("Moved \(freed)") : Text("Freed \(freed)"))
                            + Text(verbatim: " · ")
                            + Text("\(progress.completed) of \(progress.total)"))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .font(.caption)
                    }
                }
                Spacer()
            }
            if let progress = collector.deletionProgress, progress.total > 0 {
                ProgressView(
                    value: Double(min(progress.completed, progress.total)),
                    total: Double(progress.total)
                )
                .progressViewStyle(.linear)
                .controlSize(.small)
            }
        }
    }

    private var deletingTitle: String {
        let toTrash = collector.deletionProgress?.disposal == .trash
        if let name = collector.deletionProgress?.currentName, !name.isEmpty {
            return toTrash ? String(localized: "Moving \(name) to the Trash…") : String(localized: "Deleting \(name)…")
        }
        return toTrash ? String(localized: "Moving to the Trash…") : String(localized: "Deleting…")
    }

    private var doneView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let result = lastResult {
                let freed = Text(ByteFormatter.formatFileSize(result.freedBytes))
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                (result.disposal == .trash ? Text("Moved \(freed) to the Trash") : Text("Freed \(freed)"))
                    .foregroundStyle(.secondary)
                if !result.failures.isEmpty {
                    (Text(verbatim: " · ") + Text("\(result.failures.count) couldn't be removed"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .font(.callout)
    }

    private var listPanel: some View {
        PanelContainer {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(collector.items) { file in
                        CollectedRow(
                            file: file,
                            collector: collector,
                            onRemove: { collector.remove(file) },
                            onPreview: { previewItem = PreviewItem(url: file.url) }
                        )
                    }
                }
                .padding(6)
            }
            .frame(height: listHeight)
            .scrollBounceBehavior(.basedOnSize)
            .panelBackground(in: shape)
        }
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
            Text(text).lineLimit(2)
        }
        .font(.callout)
        .fontWeight(.medium)
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelBackground(tint: .orange, in: shape)
    }

    private func performDeletion(_ disposal: Collector.Disposal) async {
        phase = .deleting
        let result = await collector.deleteAll(disposal)
        lastResult = result
        phase = .done
        onDeleted(result.freedBytes)
        try? await Task.sleep(for: .seconds(2))
        if phase == .done { phase = .idle }
    }
}

private struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct CollectedRow: View {
    let file: CollectedFile
    let collector: Collector
    let onRemove: () -> Void
    let onPreview: () -> Void

    @State private var resolvedIcon: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from Collector")

            Image(nsImage: resolvedIcon
                ?? FileIcon.cached(for: file.path)
                ?? FileIcon.typeIcon(
                    forPathExtension: (file.name as NSString).pathExtension,
                    isDirectory: file.isDirectory
                ))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)

            Text(file.name).lineLimit(1)

            Spacer()

            Text(file.formattedSize)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .fileDrag({ _ in [file] }, exportsFileURLs: false) { files in
            collector.beginDragOut(files)
        } onEnd: { operation in
            collector.endDragOut(operation: operation)
        }
        .hoverHighlight(cornerRadius: 6)
        .task(id: file.path) {
            guard FileIcon.cached(for: file.path) == nil else { return }
            await FileIcon.warm(file.path)
            resolvedIcon = FileIcon.cached(for: file.path)
        }
        .contextMenu {
            Button(action: onPreview) {
                Label("Preview", systemImage: "eye")
            }
            .keyboardShortcut(.space, modifiers: [])

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Button {
                openInTerminal()
            } label: {
                Label("Open in Terminal", systemImage: "terminal")
            }

            Divider()

            Button(role: .destructive, action: onRemove) {
                Label("Remove “\(file.name)” from Collector", systemImage: "xmark.circle")
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    private func openInTerminal() {
        let directory = file.isDirectory
            ? file.path
            : (file.path as NSString).deletingLastPathComponent
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: directory)],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

private struct QuickLookSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            QuickLookView(url: url)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 680, height: 520)
    }
}

private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        if let preview = QLPreviewView(frame: .zero, style: .normal) {
            preview.autostarts = true
            preview.previewItem = url as NSURL
            preview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                preview.topAnchor.constraint(equalTo: container.topAnchor),
                preview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            context.coordinator.preview = preview
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.preview?.previewItem = url as NSURL
    }

    final class Coordinator {
        var preview: QLPreviewView?
    }
}

private struct DeleteButton: View {
    let action: () -> Void

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            Button(action: action) {
                Text("Delete").fontWeight(.semibold)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
        } else {
            legacy
        }
        #else
        legacy
        #endif
    }

    private var legacy: some View {
        Button(action: action) {
            Text("Delete")
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(nsColor: .systemRed), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct PanelContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer(content: content)
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

private extension View {
    @ViewBuilder
    func panelBackground(tint: Color? = nil, in shape: RoundedRectangle) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            materialPanelBackground(tint: tint, in: shape)
        }
        #else
        materialPanelBackground(tint: tint, in: shape)
        #endif
    }

    func materialPanelBackground(tint: Color?, in shape: RoundedRectangle) -> some View {
        background {
            ZStack {
                shape.fill(.regularMaterial)
                if let tint { shape.fill(tint.opacity(0.18)) }
            }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        }
    }
}
