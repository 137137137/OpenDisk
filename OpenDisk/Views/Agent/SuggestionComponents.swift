import AppKit
import SwiftUI

// Building blocks of `SuggestionsView`.

extension Risk {
    var title: String {
        switch self { case .low: "Safe to remove"; case .medium: "Review first"; case .high: "Use caution" }
    }

    var explanation: String {
        switch self {
        case .low: "Rebuilt automatically when needed"
        case .medium: "Check what's inside before removing"
        case .high: "May hold personal files, so choose one at a time"
        }
    }

    var color: Color {
        switch self { case .low: .green; case .medium: .orange; case .high: .red }
    }
}

/// The disk as it would look after removing the selection, in the style of
/// System Settings › Storage: selected items sit at the end of the used space,
/// next to the space they would become.
struct CapacityBar: View {
    let summary: String
    let volume: VolumeCapacity?
    let scannedBytes: Int64
    let suggestedBytes: Int64
    let selectedBytes: Int64

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Part: String, CaseIterable, Identifiable {
        case other = "Other data", suggested = "Also suggested", selected = "Selected", available = "Available"
        var id: Self { self }

        var fill: Color {
            switch self {
            case .other: .secondary.opacity(0.35)
            case .suggested: .accentColor.opacity(0.35)
            case .selected: .accentColor
            case .available: .clear
            }
        }
    }

    private func bytes(_ part: Part) -> Int64 {
        switch part {
        case .other: max(0, (volume?.used ?? scannedBytes) - suggestedBytes - selectedBytes)
        case .suggested: suggestedBytes
        case .selected: selectedBytes
        case .available: volume?.available ?? 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary).fixedSize(horizontal: false, vertical: true)
            bar
            legend
        }
        .accessibilityElement(children: .combine)
    }

    private var bar: some View {
        let total = CGFloat(max(volume?.total ?? scannedBytes, 1))
        return GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach([Part.other, .suggested, .selected].filter { bytes($0) > 0 }) { part in
                    Rectangle()
                        .fill(part.fill)
                        .frame(width: geometry.size.width * CGFloat(bytes(part)) / total)
                }
            }
        }
        .frame(height: 12)
        .background(.quaternary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
        .animation(reduceMotion ? nil : .snappy, value: selectedBytes)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(Part.allCases.filter { bytes($0) > 0 }) { part in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(part.fill)
                        .strokeBorder(part == .available ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.clear))
                        .frame(width: 9, height: 9)
                    Text(part.rawValue).foregroundStyle(.secondary)
                    Text(ByteFormatter.formatFileSize(bytes(part))).monospacedDigit()
                }
            }
        }
        .font(.subheadline)
    }
}

/// What the sheet is for, and the two places suggestions come from.
struct SourcesExplanation: View {
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            row("checkmark.shield", "Known caches",
                Text("Found by OpenDisk on its own, without AI. Nothing leaves your Mac."))
            row("sparkles", "AI suggestions",
                Text("Optional. A model you choose looks through the rest of the scan. Marked with \(Image(systemName: "sparkles")) and checked by OpenDisk's safety rules."))
        }
        .font(.callout)
    }

    private func row(_ symbol: String, _ title: String, _ text: Text) -> some View {
        GridRow {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(title).fontWeight(.medium)
            text
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RiskHeader: View {
    let risk: Risk
    let total: Int64
    let allSelected: Bool
    /// Nil hides Select All.
    let toggleAll: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(risk.color).frame(width: 7, height: 7)
            Text(risk.title).fontWeight(.semibold).foregroundStyle(.primary)
            Text(risk.explanation).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(ByteFormatter.formatFileSize(total)).monospacedDigit().foregroundStyle(.secondary)
            if let toggleAll {
                Button(allSelected ? "Deselect All" : "Select All", action: toggleAll)
                    .buttonStyle(.link)
            }
        }
        .font(.subheadline)
        .textCase(nil)
        .padding(.vertical, 2)
    }
}

struct SuggestionRow: View {
    let item: ValidatedSuggestion
    /// The model that suggested it, or nil for OpenDisk's known caches.
    let suggestedBy: String?
    @Binding var isSelected: Bool
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(item.suggestion.category, isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                    .resizable()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(item.suggestion.category)
                        if let suggestedBy {
                            Image(systemName: "sparkles")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("Suggested by \(suggestedBy)")
                                .accessibilityLabel("AI suggestion")
                        }
                    }
                    Text(item.path.abbreviatingHome()).font(.subheadline).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 12)
                Text(ByteFormatter.formatFileSize(item.size)).monospacedDigit()
                Button(action: toggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help(isExpanded ? "Hide details" : "Why this is suggested")
                .accessibilityLabel(isExpanded ? "Hide details" : "Show details")
            }
            .contentShape(Rectangle())
            .onTapGesture { isSelected.toggle() }

            if isExpanded { details }
        }
        .padding(.vertical, 2)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.suggestion.rationale)
            if let how = item.suggestion.howToRemove, !how.isEmpty {
                Text("Suggested way to remove it: \(Text(how).font(.callout.monospaced()))")
            }
            if let raised = item.riskRaisedReason {
                Text("Listed under \(item.risk.title) by OpenDisk. \(raised)")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(suggestedBy.map { "Suggested by \($0) and checked by OpenDisk's safety rules." }
                     ?? "From OpenDisk's list of known caches. No AI was used.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                }
                .buttonStyle(.link)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        // Lines up with the item name: checkbox, spacing, icon, spacing.
        .padding(.leading, 60)
        .padding(.bottom, 4)
    }
}

/// Options for asking a model to look beyond OpenDisk's known caches.
struct FindMorePopover: View {
    @Binding var provider: AIProvider
    @Binding var focus: String
    var onFind: () -> Void

    private var unavailableReason: String? {
        provider == .apple ? AIProvider.appleUnavailableReason : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find more with AI").font(.headline)
            Text("A model looks beyond the known caches for things like old installers, build folders and app data you may not need.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Using:", selection: $provider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
                TextField("Focus on:", text: $focus, prompt: Text("Optional, such as developer caches"))
                    .onSubmit { if unavailableReason == nil { onFind() } }
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(unavailableReason == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SettingsLink { Text("AI Settings…") }
                Spacer()
                Button("Find More with AI", action: onFind)
                    .keyboardShortcut(.defaultAction)
                    .disabled(unavailableReason != nil)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private var note: String {
        if let unavailableReason { return unavailableReason }
        let privacy = provider.sendsDataOffDevice
            ? "Sends file names, paths and sizes to \(provider.shortTitle), never file contents."
            : "Runs on this Mac. Nothing leaves your computer."
        return privacy + " Suggestions can be wrong, so OpenDisk leaves out protected folders and marks personal files Use caution."
    }
}
