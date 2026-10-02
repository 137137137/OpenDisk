import AppKit
import SwiftUI

/// "Free Up Space": OpenDisk's known caches show immediately, and Find More optionally asks a
/// model to look through the rest of the scan. Every suggestion is checked by
/// `SuggestionValidator` and only reaches the disk through the Collector.
struct SuggestionsView: View {
    let scan: ScanResult
    let collector: Collector

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AISettings.providerKey) private var aiProvider = AIProvider.apple
    @AppStorage(AISettings.redactKey) private var redactHome = true

    @State private var report: SuggestionReport?
    /// Instant results from OpenDisk's own catalog.
    @State private var ruleSuggestions: [Suggestion] = []
    /// Paths (expanded) whose suggestion came from a model rather than the catalog.
    @State private var aiPaths = Set<String>()
    /// The model of the latest Find More run.
    @State private var aiSourceName = ""
    @State private var selected = Set<String>()
    @State private var expanded = Set<String>()
    @State private var volume: VolumeCapacity?

    @State private var activity = AgentActivity()
    @State private var focus = ""
    @State private var runState = RunState.idle
    @State private var runTask: Task<Void, Never>?
    @State private var startedAt: Date?
    @State private var expectedDuration: TimeInterval?
    @State private var showFindMore = false
    @State private var showDetails = false
    @State private var showConsent = false

    private enum RunState: Equatable {
        case idle, running, finished, stopped
        case failed(String)
    }

    private var isRunning: Bool { runState == .running }
    private var tools: AgentTools { AgentTools(scan: scan, redact: redactHome) }

    var body: some View {
        VStack(spacing: 0) {
            CapacityHeader(
                summary: summary,
                volume: volume,
                scannedBytes: scan.tree.size(of: FileTree.rootID),
                suggestedBytes: suggestedBytes,
                selectedBytes: selectedBytes
            )
            .padding(20)
            Divider()
            suggestionList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 560, idealHeight: 640)
        .task { await loadKnownCaches() }
        .onChange(of: activity.aiSuggestions) { rebuildReport() }
        .onDisappear { runTask?.cancel() }
        .sheet(isPresented: $showConsent) {
            ConsentView(provider: aiProvider, tools: tools) {
                AISettings.grantConsent(for: aiProvider)
                showConsent = false
                run()
            }
        }
    }

    // MARK: Summary

    private var accepted: [ValidatedSuggestion] { report?.accepted ?? [] }
    private var selectedItems: [ValidatedSuggestion] { accepted.filter { selected.contains($0.path) } }
    private var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    /// Everything not selected that isn't marked Use caution.
    private var suggestedBytes: Int64 {
        accepted.filter { $0.risk != .high && !selected.contains($0.path) }.reduce(0) { $0 + $1.size }
    }

    private var place: String {
        switch scan.rootPath {
        case "/": "on your Mac"
        case UserHome.path: "in your home folder"
        default: "in \((scan.rootPath as NSString).lastPathComponent)"
        }
    }

    private var summary: String {
        let format = ByteFormatter.formatFileSize
        if report == nil { return "Checking for known caches \(place)…" }
        if selectedBytes > 0 {
            guard let volume else { return "Removing the selected items frees \(format(selectedBytes))." }
            return "Removing the selected items frees \(format(selectedBytes)), leaving \(format(volume.available + selectedBytes)) available."
        }
        if suggestedBytes > 0 {
            return "About \(format(suggestedBytes)) \(place) can likely be removed. Select items to see what you'd get back."
        }
        if isRunning { return "Looking for space you can reclaim \(place)…" }
        return "No known caches were found \(place). Find More can look through everything else."
    }

    // MARK: List

    @ViewBuilder
    private var suggestionList: some View {
        if let report, !report.accepted.isEmpty || !report.rejected.isEmpty {
            List {
                ForEach(Risk.allCases, id: \.self) { risk in
                    riskSection(risk, report.accepted.filter { $0.risk == risk })
                }
                if !report.rejected.isEmpty {
                    Section {
                        DisclosureGroup("\(report.rejected.count) \(report.rejected.count == 1 ? "item" : "items") left out by safety rules") {
                            ForEach(report.rejected) { item in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.path.abbreviatingHome()).lineLimit(1).truncationMode(.middle)
                                    Text(item.reason).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        } else if report == nil || isRunning {
            ProgressView()
        } else {
            ContentUnavailableView {
                Label("No Known Caches Found", systemImage: "internaldrive")
            } description: {
                Text("Find More can look through the rest of this scan for space you can reclaim.")
            } actions: {
                Button("Find More…") { showFindMore = true }
            }
        }
    }

    @ViewBuilder
    private func riskSection(_ risk: Risk, _ items: [ValidatedSuggestion]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    SuggestionRow(
                        item: item,
                        source: aiPaths.contains(item.path)
                            ? "Suggested by \(aiSourceName) and checked by OpenDisk."
                            : "From OpenDisk's list of known caches.",
                        isSelected: Binding(
                            get: { selected.contains(item.path) },
                            set: { if $0 { selected.insert(item.path) } else { selected.remove(item.path) } }
                        ),
                        isExpanded: expanded.contains(item.path),
                        toggleExpanded: {
                            withAnimation(reduceMotion ? nil : .snappy) {
                                if expanded.remove(item.path) == nil { expanded.insert(item.path) }
                            }
                        }
                    )
                }
            } header: {
                let paths = items.map(\.path)
                RiskHeader(
                    risk: risk,
                    total: items.reduce(0) { $0 + $1.size },
                    allSelected: paths.allSatisfy(selected.contains),
                    // Items that may hold personal files are picked one at a time.
                    toggleAll: risk == .high ? nil : {
                        if paths.allSatisfy(selected.contains) { selected.subtract(paths) } else { selected.formUnion(paths) }
                    }
                )
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            runStatus
            Spacer(minLength: 12)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(addButtonTitle, action: addToCollector)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedItems.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var addButtonTitle: String {
        switch selectedItems.count {
        case 0: "Add to Collector"
        case 1: "Add 1 Item to Collector"
        case let count: "Add \(count) Items to Collector"
        }
    }

    @ViewBuilder
    private var runStatus: some View {
        HStack(spacing: 8) {
            if isRunning {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(activity.events.last?.text ?? "Starting…")
                            .truncationMode(.middle)
                        Text(etaText(at: context.date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                }
                detailsButton
                Button("Stop", action: stop)
            } else {
                Button("Find More…") { showFindMore = true }
                    .popover(isPresented: $showFindMore, arrowEdge: .top) {
                        FindMorePopover(provider: $aiProvider, focus: $focus) {
                            showFindMore = false
                            start()
                        }
                    }
                statusText.lineLimit(1)
                if runState != .idle { detailsButton }
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch runState {
        case .finished:
            Text("Checked with \(aiSourceName).").foregroundStyle(.secondary)
        case .stopped:
            Text("Stopped. Showing what was found so far.").foregroundStyle(.secondary)
        case .failed(let message):
            Label {
                Text("Stopped early: \(message)")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .help(message)
        case .idle, .running:
            Text("Showing known caches.").foregroundStyle(.secondary)
        }
    }

    private var detailsButton: some View {
        Button("Details") { showDetails.toggle() }
            .buttonStyle(.link)
            .popover(isPresented: $showDetails, arrowEdge: .top) {
                ActivityLogView(activity: activity)
                    .frame(width: 480, height: 340)
            }
    }

    private func etaText(at now: Date) -> String {
        let elapsed = startedAt.map { now.timeIntervalSince($0) } ?? 0
        guard let expectedDuration else { return "\(Self.duration(elapsed)) elapsed" }
        let remaining = expectedDuration - elapsed
        if remaining > 5 { return "About \(Self.duration(remaining)) left" }
        if remaining > -10 { return "Almost done" }
        return "Taking longer than usual, \(Self.duration(elapsed)) so far"
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded()))
            .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }

    // MARK: Actions

    private func loadKnownCaches() async {
        let tools = self.tools
        let rootPath = scan.rootPath
        ruleSuggestions = await Task.detached { tools.knownReclaimable().map(Suggestion.init) }.value
        volume = await Task.detached { DeviceMonitor.volumeCapacity(ofPath: rootPath) }.value
        rebuildReport()
    }

    private func start() {
        guard !isRunning else { return }
        if AISettings.hasConsent(for: aiProvider) { run() } else { showConsent = true }
    }

    private func stop() {
        runTask?.cancel()
        runState = .stopped
        activity.events.append(AgentEvent(kind: .status, text: "Stopped. Keeping what was found so far."))
    }

    private func run() {
        let activity = self.activity
        activity.events = []
        activity.aiSuggestions = []
        var configured = self.tools
        configured.onEvent = { @Sendable event in Task { @MainActor in activity.events.append(event) } }
        let tools = configured
        let provider = aiProvider
        let focus = self.focus

        tools.log(.status, "Started with \(provider.shortTitle)", detail: provider.sendsDataOffDevice
            ? "Only paths and sizes are sent\(redactHome ? ", with your home folder shown as ~" : "")."
            : "Everything stays on this Mac.")
        aiSourceName = provider.shortTitle
        runState = .running
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
                tools.log(.done, "Finished with \(report?.accepted.count ?? 0) suggestions in total")
                runState = .finished
            } catch {
                guard !Task.isCancelled else { return }
                tools.log(.status, "Failed: \(error.localizedDescription)")
                runState = .failed(error.localizedDescription)
            }
        }
    }

    /// Merges catalog results with the model's (the model wins for the same path) and re-validates.
    private func rebuildReport() {
        let ai = activity.aiSuggestions
        let aiKeys = Set(ai.map { SuggestionValidator.expand($0.path) })
        let rules = ruleSuggestions.filter { !aiKeys.contains(SuggestionValidator.expand($0.path)) }
        aiPaths = aiKeys
        report = tools.validate(rules + ai)
    }

    private func addToCollector() {
        collector.add(selectedItems.map {
            CollectedFile(path: $0.path, name: $0.name, size: $0.size, isDirectory: $0.isDirectory, viaTrash: true)
        })
        dismiss()
    }
}
