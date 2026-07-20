import SwiftUI
import AppKit

/// DaisyDisk-style deletion tray, rendered in the functional layer with
/// Liquid Glass. Lists the collected files, shows a running total, arms a
/// countdown before permanently deleting them, and reports the space freed.
/// Collapses to nothing while idle and empty.
struct CollectorBar: View {
    let collector: Collector
    /// Called after a deletion with the freed byte count, so the host can
    /// rescan and bring the updated usage back to the top.
    var onDeleted: (Int64) -> Void

    private static let countdownSeconds = 5

    @State private var phase: Phase = .idle
    @State private var secondsLeft = CollectorBar.countdownSeconds
    @State private var countdownTask: Task<Void, Never>?
    @State private var previewURL: URL?
    @State private var lastResult: Collector.Result?

    private enum Phase: Equatable { case idle, countdown, deleting, done }

    var body: some View {
        Group {
            if collector.isEmpty && phase == .idle {
                EmptyView()
            } else {
                GlassEffectContainer {
                    content
                        .padding(12)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: collector.isEmpty)
        .animation(.spring(duration: 0.3), value: phase)
        .quickLookPreview($previewURL)
    }

    // MARK: - Phase content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:      collectingView
        case .countdown: countdownView
        case .deleting:  deletingView
        case .done:      doneView
        }
    }

    private var collectingView: some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(collector.items) { file in
                        CollectedRow(
                            file: file,
                            onRemove: { collector.remove(file) },
                            onPreview: { previewURL = file.url }
                        )
                    }
                }
            }
            .frame(maxHeight: 220)
            .scrollBounceBehavior(.basedOnSize)

            Divider().opacity(0.4)

            HStack(spacing: 12) {
                totalBadge
                Text(totalParts.unit).fontWeight(.semibold)
                    + Text(" collected").foregroundColor(.secondary)
                Spacer()
                Button(role: .destructive) {
                    arm()
                } label: {
                    Text("Delete").frame(minWidth: 64)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(collector.isEmpty)
            }
        }
    }

    private var countdownView: some View {
        HStack(spacing: 14) {
            countdownRing
            Text("\(secondsLeft) ").fontWeight(.semibold).monospacedDigit()
                + Text("seconds to start. The files will be ").foregroundColor(.secondary)
                + Text("deleted forever!").foregroundColor(.red).fontWeight(.semibold)
            Spacer()
            Button("Stop") { cancelCountdown() }
                .buttonStyle(.glass)
                .controlSize(.large)
        }
        .padding(.vertical, 4)
    }

    private var deletingView: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Deleting…").foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 12)
    }

    private var doneView: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            if let result = lastResult {
                Text("Freed ").foregroundColor(.secondary)
                    + Text(ByteFormatter.formatFileSize(result.freedBytes)).fontWeight(.semibold)
                if !result.failures.isEmpty {
                    Text(" · \(result.failures.count) couldn't be removed")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .padding(.vertical, 12)
    }

    // MARK: - Pieces

    private var totalBadge: some View {
        ZStack {
            Circle().strokeBorder(.tint, lineWidth: 3)
            Text(totalParts.value)
                .font(.headline)
                .monospacedDigit()
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .padding(8)
        }
        .frame(width: 60, height: 60)
    }

    private var countdownRing: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(secondsLeft) / CGFloat(Self.countdownSeconds))
                .stroke(.red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: secondsLeft)
            Text("\(secondsLeft)").font(.headline).monospacedDigit()
        }
        .frame(width: 52, height: 52)
    }

    /// Splits "384.7 MB" into ("384.7", "MB") for the badge + label.
    private var totalParts: (value: String, unit: String) {
        let parts = collector.formattedTotal.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return (collector.formattedTotal, "") }
        return (String(parts[0]), String(parts[1]))
    }

    // MARK: - Actions

    private func arm() {
        guard !collector.isEmpty else { return }
        secondsLeft = Self.countdownSeconds
        phase = .countdown
        countdownTask = Task {
            for _ in 0..<Self.countdownSeconds {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                secondsLeft -= 1
            }
            if Task.isCancelled { return }
            await performDeletion()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        phase = .idle
    }

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
