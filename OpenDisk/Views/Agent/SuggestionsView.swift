import AppKit
import SwiftUI

/// "Free Up Space": finds reclaimable space with OpenDisk's rules and, optionally, an AI.
/// Every suggestion is checked by `SuggestionValidator` and can only reach the disk
/// through the Collector.
struct SuggestionsView: View {
    let scan: ScanResult
    let collector: Collector

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AISettings.providerKey) private var providerRaw = AIProvider.rules.rawValue
    @AppStorage(AISettings.redactKey) private var redactHome = true
    @State private var focus = ""
    @State private var isRunning = false
    @State private var report: SuggestionReport?
    @State private var errorMessage: String?
    @State private var selected = Set<String>()
    @State private var showConsent = false
    @State private var runTask: Task<Void, Never>?
    @State private var activity = AgentActivity()
    @State private var showActivity = false
    /// Instant results from OpenDisk's own catalog, shown before the AI replies.
    @State private var ruleSuggestions: [Suggestion] = []
    /// Paths (expanded) whose suggestion came from the AI rather than the catalog.
    @State private var aiPaths = Set<String>()
    @State private var startedAt: Date?
    @State private var expectedDuration: TimeInterval?
    @State private var expanded = Set<String>()

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .rules }
    private var tools: AgentTools { AgentTools(scan: scan, redact: redactHome) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if report == nil && !isRunning && errorMessage == nil {
                    IntroView(provider: provider, rootName: rootName)
                } else {
                    resultsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 600, idealHeight: 680)
        .sheet(isPresented: $showConsent) {
            ConsentView(provider: provider, tools: tools) {
                AISettings.grantConsent(for: provider)
                showConsent = false
                run()
            }
        }
        .onDisappear { runTask?.cancel() }
        .onChange(of: activity.aiSuggestions) { rebuildReport() }
    }

    private var rootName: String {
        scan.rootPath == UserHome.path ? "your home folder" : (scan.rootPath as NSString).lastPathComponent
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free Up Space").font(.title2.weight(.semibold))
                    Text("Find files and folders you can safely remove from \(rootName).")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ProviderMenu(providerRaw: $providerRaw)
                    .disabled(isRunning)
            }
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "scope").foregroundStyle(.secondary)
                    TextField("Focus on something specific (optional), e.g. “developer caches”", text: $focus)
                        .textFieldStyle(.plain)
                        .onSubmit(start)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
                .disabled(isRunning)

                if isRunning {
                    Button("Stop", role: .cancel, action: stop)
                        .controlSize(.large)
                } else {
                    Button(action: start) {
                        Label(report == nil ? "Analyze" : "Analyze Again", systemImage: "sparkle.magnifyingglass")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
    }

    // MARK: Results

    private var resultsView: some View {
        VStack(spacing: 0) {
            SummaryCard(
                report: report,
                isRunning: isRunning,
                statusText: activity.events.last?.text,
                startedAt: startedAt,
                expectedDuration: expectedDuration,
                etaText: etaText,
                errorMessage: errorMessage,
                showsDetailsToggle: provider != .rules && !activity.events.isEmpty,
                showActivity: $showActivity
            )
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            if showActivity && provider != .rules {
                ActivityLogView(activity: activity)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let report, !report.accepted.isEmpty || !report.rejected.isEmpty {
                suggestionList(report)
            } else {
                Spacer()
                if isRunning {
                    VStack(spacing: 6) {
                        Text("Suggestions will appear here as they're found.")
                            .foregroundStyle(.secondary)
                    }
                } else if errorMessage == nil {
                    ContentUnavailableView(
                        "Nothing to Remove", systemImage: "checkmark.seal",
                        description: Text("No caches or other reclaimable space were found in this scan.")
                    )
                }
                Spacer()
            }
        }
    }

    private func suggestionList(_ report: SuggestionReport) -> some View {
        List {
            ForEach(Risk.allCases, id: \.self) { risk in
                riskSection(risk, report.accepted.filter { $0.risk == risk })
            }
            if !report.rejected.isEmpty {
                Section {
                    DisclosureGroup {
                        ForEach(report.rejected) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text((item.path as NSString).lastPathComponent)
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    } label: {
                        Label {
                            Text("\(report.rejected.count) suggestion\(report.rejected.count == 1 ? " was" : "s were") blocked by OpenDisk's safety rules")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "hand.raised.fill").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .animation(.snappy, value: report.accepted.map(\.id))
    }

    @ViewBuilder
    private func riskSection(_ risk: Risk, _ items: [ValidatedSuggestion]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    SuggestionRow(
                        item: item,
                        fromAI: aiPaths.contains(item.path),
                        isSelected: selected.contains(item.path),
                        isExpanded: expanded.contains(item.path),
                        toggleSelected: { toggle(item.path, in: &selected) },
                        toggleExpanded: { withAnimation(.snappy) { toggle(item.path, in: &expanded) } }
                    )
                }
            } header: {
                RiskSectionHeader(
                    risk: risk,
                    total: items.reduce(0) { $0 + $1.size },
                    count: items.count,
                    allSelected: items.allSatisfy { selected.contains($0.path) },
                    onSelectAll: risk == .high ? nil : {
                        let paths = items.map(\.path)
                        if paths.allSatisfy(selected.contains) { selected.subtract(paths) } else { selected.formUnion(paths) }
                    }
                )
            }
        }
    }

    private func toggle(_ path: String, in set: inout Set<String>) {
        if set.contains(path) { set.remove(path) } else { set.insert(path) }
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

    // MARK: Footer

    private var selectedItems: [ValidatedSuggestion] {
        report?.accepted.filter { selected.contains($0.path) } ?? []
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label(provider.disclaimer, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(provider.disclaimer)
            Spacer(minLength: 16)
            let items = selectedItems
            if !items.isEmpty {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(items.count) selected · \(ByteFormatter.formatFileSize(items.reduce(0) { $0 + $1.size }))")
                        .font(.callout.weight(.medium)).monospacedDigit()
                    Text("Moved to the Trash when you delete")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add to Collector") {
                collector.add(items.map {
                    CollectedFile(path: $0.path, name: $0.name, size: $0.size, isDirectory: $0.isDirectory, viaTrash: true)
                })
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(items.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Actions

    private func start() {
        guard !isRunning else { return }
        if AISettings.hasConsent(for: provider) { run() } else { showConsent = true }
    }

    private func stop() {
        runTask?.cancel()
        isRunning = false
        activity.events.append(AgentEvent(kind: .status, text: "Stopped. Keeping the suggestions found so far."))
    }

    private func run() {
        let activity = self.activity
        activity.events = []
        activity.aiSuggestions = []
        var configured = self.tools
        configured.onEvent = { @Sendable event in Task { @MainActor in activity.events.append(event) } }
        let tools = configured
        let provider = self.provider
        let focus = self.focus

        errorMessage = nil
        selected = []
        aiPaths = []
        // Known caches show instantly; the AI then adds to or refines them.
        ruleSuggestions = tools.knownReclaimable().map(Suggestion.init)
        rebuildReport()
        guard provider != .rules else { return }

        tools.log(.status, "Started with \(provider.title)", detail: provider.sendsDataOffDevice
            ? "Only paths and sizes are sent\(redactHome ? ", with your home folder shown as ~" : "")."
            : "Everything stays on this Mac.")
        isRunning = true
        startedAt = Date()
        expectedDuration = AIDurationEstimate.expected(for: provider)
        let onUpdate: SuggestionUpdate = { suggestions in
            Task { @MainActor in activity.aiSuggestions = suggestions }
        }
        runTask = Task {
            let start = Date()
            do {
                let suggestions = try await provider.makeProvider().suggest(focus: focus, tools: tools, onUpdate: onUpdate)
                guard !Task.isCancelled else { return }
                activity.aiSuggestions = suggestions
                AIDurationEstimate.record(Date().timeIntervalSince(start), for: provider)
                let report = tools.validate(suggestions)
                tools.log(.done, "Finished: \(report.accepted.count) kept, \(report.rejected.count) filtered out by OpenDisk's safety rules")
            } catch {
                guard !Task.isCancelled else { return }
                tools.log(.status, "Failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
            isRunning = false
        }
    }

    /// Merges catalog results with the AI's (the AI wins for the same path) and re-validates.
    private func rebuildReport() {
        let ai = activity.aiSuggestions
        let aiKeys = Set(ai.map { SuggestionValidator.expand($0.path) })
        let rules = ruleSuggestions.filter { !aiKeys.contains(SuggestionValidator.expand($0.path)) }
        aiPaths = aiKeys
        report = tools.validate(rules + ai)
    }
}


// MARK: - Risk presentation

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

extension AIProvider {
    var shortTitle: String {
        switch self {
        case .rules: "Built-in Rules"
        case .apple: "Apple Intelligence"
        case .anthropic: "Claude · \(AISettings.anthropicModel)"
        case .openAICompatible: AISettings.openAIModel
        }
    }
    var symbol: String {
        switch self {
        case .rules: "list.bullet.rectangle.portrait"
        case .apple: "apple.logo"
        case .anthropic: "sparkle"
        case .openAICompatible: "network"
        }
    }
}

// MARK: - Components

private struct ProviderMenu: View {
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
private struct IntroView: View {
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
    }
}

/// Headline total, a capacity-style bar split by risk, and live progress.
private struct SummaryCard: View {
    let report: SuggestionReport?
    let isRunning: Bool
    let statusText: String?
    let startedAt: Date?
    let expectedDuration: TimeInterval?
    let etaText: (TimeInterval) -> String
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
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
                    Text(etaText(elapsed))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    detailsButton
                }
                .font(.callout)
            }
        }
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
private struct RiskBar: View {
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

private struct RiskSectionHeader: View {
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

private struct SuggestionRow: View {
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
            detail("folder", item.path) {
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
        detail(symbol, text) { EmptyView() }
    }

    private func detail<Accessory: View>(_ symbol: String, _ text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(text).font(.callout).textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 8)
            accessory()
        }
    }
}

@MainActor
@Observable
final class AgentActivity {
    var events: [AgentEvent] = []
    /// Everything the AI has proposed so far; updated while it's still working.
    var aiSuggestions: [Suggestion] = []
}

/// Step-by-step log of what the agent is doing; each step expands to show the raw
/// arguments, tool results and model text.
private struct ActivityLogView: View {
    let activity: AgentActivity

    var body: some View {
        ScrollViewReader { proxy in
            List(activity.events) { event in
                ActivityRow(event: event).id(event.id)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onChange(of: activity.events.count) {
                if let last = activity.events.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ActivityRow: View {
    let event: AgentEvent
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
                Text(event.text).lineLimit(expanded ? nil : 1).truncationMode(.middle)
                Spacer()
                Text(event.date.formatted(date: .omitted, time: .standard))
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                if event.detail != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            if expanded, let detail = event.detail {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if event.detail != nil { withAnimation(.snappy) { expanded.toggle() } } }
    }

    private var icon: String {
        switch event.kind {
        case .status: "info.circle"
        case .request: "arrow.up.circle"
        case .model: "text.bubble"
        case .tool: "wrench.and.screwdriver"
        case .done: "checkmark.circle"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .model: .purple
        case .tool: .blue
        case .done: .green
        default: .secondary
        }
    }
}

/// Shown once per off-device provider: states what is sent and shows the exact payload.
private struct ConsentView: View {
    let provider: AIProvider
    let tools: AgentTools
    var onAgree: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preview: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send scan data to \(provider.title)?").font(.headline)
            Text("""
            OpenDisk sends folder and file paths with their sizes, so the model can look around your scan. It never sends file contents. \
            \(AISettings.redactHome ? "Your home folder is shown as ~." : "Full paths are sent, including your user name. You can hide it in Settings › AI.") \
            Your provider's data policy applies to what is sent.
            """)
            .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Preview the first message") {
                ScrollView {
                    Text(preview ?? "Loading…")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Send", action: onAgree).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
        .task {
            let tools = tools
            preview = await Task.detached { tools.briefing() }.value
        }
    }
}
