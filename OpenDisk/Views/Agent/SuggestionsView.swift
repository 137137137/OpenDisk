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
                .card(cornerRadius: 8)
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
                errorMessage: errorMessage,
                showsDetailsToggle: provider != .rules && !activity.events.isEmpty,
                showActivity: $showActivity
            )
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            if showActivity && provider != .rules {
                ActivityLogView(activity: activity)
                    .frame(height: 200)
                    .card(cornerRadius: 10)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let report, !report.accepted.isEmpty || !report.rejected.isEmpty {
                suggestionList(report)
            } else {
                Spacer()
                if isRunning {
                    Text("Suggestions will appear here as they're found.")
                        .foregroundStyle(.secondary)
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
                AIDurationEstimate.record(Date().timeIntervalSince(start), for: provider)
                activity.aiSuggestions = suggestions
                rebuildReport()
                tools.log(.done, "Finished: \(report?.accepted.count ?? 0) kept, \(report?.rejected.count ?? 0) blocked by OpenDisk's safety rules")
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
