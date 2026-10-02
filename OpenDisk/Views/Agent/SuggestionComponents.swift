import AppKit
import SwiftUI

// Building blocks of `SuggestionsView`.

extension Risk {
    var title: String {
        switch self { case .low: "Safe to Remove"; case .medium: "Review First"; case .high: "Be Careful" }
    }
    var shortTitle: String {
        switch self { case .low: "Safe"; case .medium: "Review"; case .high: "Careful" }
    }
    var explanation: String {
        switch self {
        case .low: "Caches and build files that are rebuilt automatically when needed."
        case .medium: "Probably fine to remove, but have a look at what's inside first."
        case .high: "May hold personal data or things you can't get back. Choose items one at a time."
        }
    }
    var symbol: String {
        switch self { case .low: "checkmark.shield.fill"; case .medium: "eye.fill"; case .high: "exclamationmark.triangle.fill" }
    }
    var color: Color {
        switch self { case .low: .green; case .medium: .orange; case .high: .red }
    }
}

extension View {
    /// Rounded panel on the control background with a hairline border.
    func card(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Color(nsColor: .controlBackgroundColor), in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.separator))
    }
}

struct ProviderMenu: View {
    @Binding var providerRaw: String
    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .rules }

    var body: some View {
        Menu {
            Picker("Suggestions From", selection: $providerRaw) {
                ForEach(AIProvider.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Divider()
            SettingsLink { Text("AI Settings…") }
        } label: {
            Label(provider.shortTitle, systemImage: provider.symbol)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .help("Choose who makes the suggestions")
    }
}

/// First-run explanation: what happens, in three steps, and what is shared.
struct IntroView: View {
    let provider: AIProvider
    let rootName: String

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 16) {
                step(1, "Analyze", "magnifyingglass",
                     provider == .rules
                        ? "OpenDisk checks \(rootName) for known caches and build folders."
                        : "OpenDisk and \(provider.shortTitle) look through \(rootName) for space you can reclaim.")
                step(2, "Review", "checklist",
                     "Every suggestion is rated Safe, Review or Careful, and checked against OpenDisk's safety rules.")
                step(3, "Collect", "tray.and.arrow.down",
                     "Add what you want to the Collector. Suggested items go to the Trash, so you can restore them.")
            }
            .padding(.horizontal, 24)

            Label {
                Text(provider.sendsDataOffDevice
                     ? "Only file names, paths and sizes are shared with \(provider.shortTitle), never file contents."
                     : "Everything stays on this Mac.")
            } icon: {
                Image(systemName: provider.sendsDataOffDevice ? "lock.shield" : "lock.fill")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 24)
    }

    private func step(_ number: Int, _ title: String, _ symbol: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)
                .frame(height: 34)
            Text("\(number). \(title)").font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .card(cornerRadius: 12)
    }
}

/// Headline total, a capacity-style bar split by risk, and live progress.
struct SummaryCard: View {
    let report: SuggestionReport?
    let isRunning: Bool
    let statusText: String?
    let startedAt: Date?
    let expectedDuration: TimeInterval?
    let errorMessage: String?
    let showsDetailsToggle: Bool
    @Binding var showActivity: Bool

    private var accepted: [ValidatedSuggestion] { report?.accepted ?? [] }
    private func total(_ risk: Risk) -> Int64 { accepted.filter { $0.risk == risk }.reduce(0) { $0 + $1.size } }
    private var reclaimable: Int64 { total(.low) + total(.medium) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ByteFormatter.formatFileSize(reclaimable))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: reclaimable)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isRunning ? "found so far" : "can likely be freed")
                        .font(.headline)
                    Text("\(accepted.count) suggestion\(accepted.count == 1 ? "" : "s")" +
                         (total(.high) > 0 ? " · \(ByteFormatter.formatFileSize(total(.high))) more needs care" : ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }

            RiskBar(totals: Risk.allCases.map { ($0, total($0)) })

            if isRunning {
                progressRow
            } else if let errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The analysis stopped early").font(.callout.weight(.semibold))
                        Text(errorMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    detailsButton
                }
            } else if showsDetailsToggle {
                HStack {
                    Label("Analysis complete", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    detailsButton
                }
            }
        }
        .padding(18)
        .card(cornerRadius: 14)
    }

    private var progressRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = startedAt.map { context.date.timeIntervalSince($0) } ?? 0
            VStack(alignment: .leading, spacing: 8) {
                if let expectedDuration {
                    // Caps at 95% so it never looks finished before it is.
                    ProgressView(value: min(elapsed / expectedDuration, 0.95))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(statusText ?? "Starting…")
                        .lineLimit(1).truncationMode(.middle)
                        .contentTransition(.opacity)
                    Spacer(minLength: 12)
                    Text(etaText(elapsed: elapsed))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    detailsButton
                }
                .font(.callout)
            }
        }
    }

    private func etaText(elapsed: TimeInterval) -> String {
        guard let expectedDuration else { return "Estimating time… \(Self.formatSeconds(elapsed)) so far" }
        let remaining = expectedDuration - elapsed
        if remaining > 5 { return "About \(Self.formatSeconds(remaining)) remaining" }
        if remaining > -10 { return "Almost done…" }
        return "Taking longer than usual · \(Self.formatSeconds(elapsed)) so far"
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s < 60 ? "\(s) sec" : "\(s / 60) min \(s % 60) sec"
    }

    @ViewBuilder
    private var detailsButton: some View {
        if showsDetailsToggle {
            Button {
                withAnimation(.snappy) { showActivity.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text(showActivity ? "Hide Details" : "Show Details")
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .rotationEffect(.degrees(showActivity ? 180 : 0))
                }
            }
            .buttonStyle(.link)
        }
    }
}

/// Storage-style bar like System Settings › Storage, one segment per risk level.
struct RiskBar: View {
    let totals: [(Risk, Int64)]

    var body: some View {
        let sum = max(totals.reduce(0) { $0 + $1.1 }, 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(totals.filter { $0.1 > 0 }, id: \.0) { risk, size in
                        Rectangle().fill(risk.color.gradient)
                            .frame(width: max(4, (geometry.size.width - 4) * CGFloat(size) / CGFloat(sum)))
                    }
                    if totals.allSatisfy({ $0.1 == 0 }) { Color.secondary.opacity(0.15) }
                }
                .clipShape(Capsule())
                .animation(.snappy, value: totals.map(\.1))
            }
            .frame(height: 10)

            HStack(spacing: 16) {
                ForEach(totals, id: \.0) { risk, size in
                    HStack(spacing: 5) {
                        Circle().fill(risk.color).frame(width: 8, height: 8)
                        Text(risk.shortTitle).foregroundStyle(.secondary)
                        Text(ByteFormatter.formatFileSize(size)).monospacedDigit()
                    }
                }
            }
            .font(.caption)
        }
    }
}

struct RiskSectionHeader: View {
    let risk: Risk
    let total: Int64
    let count: Int
    let allSelected: Bool
    let onSelectAll: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: risk.symbol).foregroundStyle(risk.color)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(risk.title).font(.headline).foregroundStyle(.primary)
                    Text("\(count) · \(ByteFormatter.formatFileSize(total))")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(risk.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .textCase(nil)
            }
            Spacer()
            if let onSelectAll {
                Button(allSelected ? "Deselect All" : "Select All", action: onSelectAll)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .textCase(nil)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

struct SuggestionRow: View {
    let item: ValidatedSuggestion
    let fromAI: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let toggleSelected: () -> Void
    let toggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: toggleSelected) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "Deselect \(item.name)" : "Select \(item.name)")

                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                    .resizable()
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                        if fromAI {
                            Image(systemName: "sparkles")
                                .font(.caption)
                                .foregroundStyle(.purple)
                                .help("Suggested by AI, checked by OpenDisk")
                        }
                    }
                    Text(item.suggestion.rationale)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 1)
                }

                Spacer(minLength: 8)

                Text(ByteFormatter.formatFileSize(item.size))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()

                Button(action: toggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide details" : "Show details")
            }

            if isExpanded { details }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleSelected)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                detail("folder", item.path)
                Spacer(minLength: 8)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                }
                .buttonStyle(.link)
            }
            detail("tag", item.suggestion.category + (item.suggestion.regenerates ? " · Rebuilt automatically" : ""))
            detail(fromAI ? "sparkles" : "list.bullet.rectangle.portrait",
                   fromAI ? "Suggested by AI, checked by OpenDisk's safety rules" : "From OpenDisk's list of known caches")
            if let how = item.suggestion.howToRemove, !how.isEmpty {
                detail("terminal", "Recommended: \(how)")
            }
            if let raised = item.riskRaisedReason {
                Label("OpenDisk rated this “\(item.risk.shortTitle)”: \(raised)", systemImage: "shield.lefthalf.filled")
                    .font(.callout)
                    .foregroundStyle(item.risk.color)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.leading, 72)
    }

    private func detail(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.callout).textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
        }
    }
}
