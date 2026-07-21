import SwiftUI
import AppKit
import Quartz

/// DaisyDisk-style deletion tray in the Liquid Glass functional layer. A
/// compact footer (total + Delete) sits in the layout below the chart;
/// hovering reveals the collected-file list, which floats *upward* over the
/// chart — anchored just above the footer so it never covers the controls or
/// resizes the graph.
struct CollectorBar: View {
    let collector: Collector
    /// True while a drag is hovering the drop target — drives the highlight.
    var isTargeted: Bool = false
    /// Called after a deletion with the freed byte count, so the host can
    /// rescan and bring the updated usage back to the top.
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

    /// Whether the pointer (or an active drag) currently wants the list open.
    /// Drives `listVisible` through a short close delay so crossing the small
    /// gap between the footer and the floating list doesn't collapse it.
    private var wantsList: Bool {
        phase == .idle && !collector.isEmpty && (footerHovered || listHovered || isTargeted)
    }

    /// A macOS-protected item is being dragged: the tray refuses it and says so
    /// immediately (the moment it's picked up — not only once it's over the
    /// tray), so the user never even gets to drop it.
    private var rejecting: Bool {
        phase == .idle && collector.draggedProtectedReason != nil
    }

    /// Content height for the floating list: ~one row per item (plus the
    /// panel's own padding), capped so it never overruns the window — only
    /// as tall as it needs to be, then scrolls.
    private var listHeight: CGFloat {
        min(600, CGFloat(collector.count) * 30 + 16)
    }

    var body: some View {
        footerBar
            .onHover { footerHovered = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            // Floating layers are anchored to the footer's bottom, then pushed
            // up by the footer's own height so they sit fully above it (over
            // the graph) without covering the Delete button.
            .overlay(alignment: .bottom) {
                if listVisible {
                    listPanel
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
            // Open immediately, close after a short delay: moving the pointer
            // from the footer up to the list (or back) crosses an 8pt gap that
            // belongs to neither hover region. Without the delay the list would
            // flash shut mid-transit; a re-entry cancels the pending close.
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
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
            .animation(.spring(duration: 0.3), value: collector.count)
            .animation(.spring(duration: 0.3), value: phase)
            .animation(.spring(duration: 0.3), value: collector.blockedNotice)
            .animation(.easeInOut(duration: 0.15), value: rejecting)
            .animation(.snappy(duration: 0.25), value: collector.deletionProgress)
            .sheet(item: $previewItem) { item in
                QuickLookSheet(url: item.url)
            }
            // Native double-confirmation instead of a countdown.
            .confirmationDialog(
                "Delete \(collector.count) item\(collector.count == 1 ? "" : "s")?",
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete \(collector.formattedTotal)", role: .destructive) {
                    Task { await performDeletion() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes the collected items and can’t be undone.")
            }
    }

    // MARK: - Footer (always in layout)

    private var footerBar: some View {
        GlassEffectContainer {
            footerContent
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(
                    rejecting ? .regular.tint(.red)
                        : (isTargeted ? .regular.tint(.accentColor) : .regular),
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(
                        rejecting ? Color.red : (isTargeted ? Color.accentColor : .clear),
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

    /// Replaces the footer while a protected item is being dragged: a clear,
    /// immediate "you can't collect this" with the specific reason.
    private var rejectionView: some View {
        HStack(spacing: 8) {
            Image(systemName: "nosign")
            Text(collector.draggedProtectedReason ?? "This item can’t be deleted")
                .lineLimit(2)
        }
        .font(.callout)
        .fontWeight(.semibold)
        .foregroundStyle(.red)
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
                Text("\(collector.count) item\(collector.count == 1 ? "" : "s") collected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showConfirm = true
            } label: {
                Text("Delete")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .systemRed), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(collector.isEmpty)
        }
    }

    /// Shown when nothing is collected yet: the persistent drop-target hint,
    /// which lights up while a drag is hovering.
    private var hintView: some View {
        HStack(spacing: 8) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.down.circle.dotted")
            Text(isTargeted ? "Release to collect" : "Drag files here to collect them for deletion")
        }
        .font(.callout)
        .fontWeight(isTargeted ? .semibold : .regular)
        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
        .frame(maxWidth: .infinity)
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
                    if let progress = collector.deletionProgress {
                        HStack(spacing: 0) {
                            Text("Freed ").foregroundStyle(.secondary)
                            Text(ByteFormatter.formatFileSize(progress.freedBytes))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text(" · \(progress.completed) of \(progress.total)")
                                .foregroundStyle(.secondary)
                        }
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

    /// Names the item currently being removed, e.g. "Deleting npm Cache…".
    private var deletingTitle: String {
        if let name = collector.deletionProgress?.currentName, !name.isEmpty {
            return "Deleting \(name)…"
        }
        return "Deleting…"
    }

    private var doneView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let result = lastResult {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Freed ").foregroundStyle(.secondary)
                    Text(ByteFormatter.formatFileSize(result.freedBytes)).fontWeight(.semibold)
                }
                if !result.failures.isEmpty {
                    Text(" · \(result.failures.count) couldn't be removed")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .font(.callout)
    }

    // MARK: - Floating layers (overlay, over the chart)

    private var listPanel: some View {
        GlassEffectContainer {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(collector.items) { file in
                        CollectedRow(
                            file: file,
                            onRemove: { collector.remove(file) },
                            onPreview: { previewItem = PreviewItem(url: file.url) }
                        )
                    }
                }
                .padding(6)
            }
            // Explicit content-based height: the list is an overlay on the
            // short footer, so a plain maxHeight gets squeezed to the footer's
            // height. Force a height that grows with the item count (only as
            // tall as needed) up to a generous cap, then scroll.
            .frame(height: listHeight)
            .scrollBounceBehavior(.basedOnSize)
            .glassEffect(.regular, in: shape)
        }
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
            Text(text).lineLimit(2)
        }
        .font(.callout)
        .foregroundStyle(.orange)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange), in: shape)
    }

    // MARK: - Actions

    private func performDeletion() async {
        phase = .deleting
        let result = await collector.deleteAll()
        lastResult = result
        phase = .done
        onDeleted(result.freedBytes)
        try? await Task.sleep(for: .seconds(2))
        if phase == .done { phase = .idle }
    }
}

/// Identifiable wrapper so a URL can drive a `.sheet(item:)`.
private struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// A single collected file inside the tray: native icon, name, size, and the
/// Preview / Show in Finder / Open in Terminal / Remove context menu.
private struct CollectedRow: View {
    let file: CollectedFile
    let onRemove: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from Collector")

            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
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
        .hoverHighlight(cornerRadius: 6)
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

/// Native Quick Look preview shown in a sheet, wrapping AppKit's
/// `QLPreviewView` (SwiftUI's `quickLookPreview` modifier is iOS-only).
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
