import AppKit
import SwiftUI

struct AISettingsSection: View {
    @AppStorage(AISettings.providerKey) private var provider = AIProvider.apple
    @AppStorage(AISettings.redactKey) private var redactHome = true
    @AppStorage(AISettings.anthropicModelKey) private var anthropicModel = AISettings.defaultAnthropicModel
    @AppStorage(AISettings.openAIModelKey) private var openAIModel = AISettings.defaultOpenAIModel
    @AppStorage(AISettings.openAIBaseURLKey) private var openAIBaseURL = AISettings.defaultOpenAIBaseURL
    @State private var apiKey = ""
    @State private var connection: ConnectionState = .idle
    @State private var models: [String] = []
    @State private var modelsError: String?
    @State private var isLoadingModels = false

    private enum ConnectionState: Equatable {
        case idle, testing
        case success(String)
        case failure(String)
    }

    var body: some View {
        Section {
            Picker("Find More uses", selection: $provider) {
                ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
            }

            switch provider {
            case .apple:
                if let reason = AIProvider.appleUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
            case .anthropic:
                SecureField("API key", text: $apiKey)
                TextField("Model", text: $anthropicModel)
            case .openAICompatible:
                TextField("Base URL", text: $openAIBaseURL)
                SecureField("API key (optional for local servers)", text: $apiKey)
                modelPicker
            }

            LabeledContent {
                Button("Test Connection", action: testConnection)
                    .disabled(connection == .testing)
            } label: {
                connectionStatus
            }

            Text(provider.disclaimer).font(.caption).foregroundStyle(.secondary)

            Toggle(isOn: $redactHome) {
                VStack(alignment: .leading) {
                    Text("Hide my home folder path")
                    Text("Shows it as ~ in exports and anything sent to an AI provider.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let mcpPath = MCPHelper.executablePath {
                LabeledContent("MCP server") {
                    Button("Copy Claude Code Command") { MCPHelper.copy(MCPHelper.claudeCodeCommand(mcpPath)) }
                    Button("Copy JSON Config") { MCPHelper.copy(MCPHelper.jsonConfig(mcpPath)) }
                }
                Text("Lets Claude Desktop, Claude Code and other MCP clients read your saved scans and history. Read-only: it can't delete anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Label("AI Suggestions", systemImage: "sparkles")
        }
        .onAppear(perform: loadKey)
        .onChange(of: provider) { loadKey() }
        .onChange(of: apiKey) { saveKey() }
        // Any change to what would be tested makes the last result stale.
        .onChange(of: [provider.rawValue, apiKey, anthropicModel, openAIModel, openAIBaseURL]) { connection = .idle }
        // Refetch when the provider, server or key changes, after typing pauses.
        .task(id: "\(provider.rawValue)|\(openAIBaseURL)|\(apiKey)") {
            guard provider == .openAICompatible else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await loadModels()
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        LabeledContent("Model") {
            HStack {
                if models.isEmpty {
                    TextField("Model", text: $openAIModel).labelsHidden()
                } else {
                    Picker("Model", selection: $openAIModel) {
                        // Keep a typed or previously saved name selectable even if the server doesn't list it.
                        if !models.contains(openAIModel) { Text(openAIModel).tag(openAIModel) }
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                if isLoadingModels {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh Models", systemImage: "arrow.clockwise") {
                        Task { await loadModels() }
                    }
                    .labelStyle(.iconOnly)
                    .help("Fetch the models this server offers")
                }
                if !models.isEmpty {
                    Button("Type a Name", systemImage: "character.cursor.ibeam") { models = [] }
                        .labelStyle(.iconOnly)
                        .help("Enter a model name that isn't listed")
                }
            }
        }
        if let modelsError {
            Text(modelsError).font(.caption).foregroundStyle(.orange)
        } else if !models.isEmpty {
            Text("\(models.count) models available on this server.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadModels() async {
        guard provider == .openAICompatible else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let fetched = try await OpenAICompatibleProvider.availableModels(baseURL: openAIBaseURL, apiKey: apiKey)
            models = fetched
            modelsError = fetched.isEmpty ? "The server returned no models. Type the model name instead." : nil
            if let first = fetched.first, !fetched.contains(openAIModel),
               openAIModel == AISettings.defaultOpenAIModel {
                openAIModel = first
            }
        } catch {
            models = []
            modelsError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch connection {
        case .idle:
            Text("Sends a one-word request. No scan data is sent.")
                .font(.caption).foregroundStyle(.secondary)
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func testConnection() {
        saveKey()
        let provider = provider
        connection = .testing
        Task {
            do {
                connection = .success(try await provider.testConnection())
            } catch {
                connection = .failure(error.localizedDescription)
            }
        }
    }

    private func loadKey() {
        apiKey = provider.sendsDataOffDevice ? Keychain.read(account: provider.rawValue) ?? "" : ""
    }

    private func saveKey() {
        guard provider.sendsDataOffDevice else { return }
        if apiKey != (Keychain.read(account: provider.rawValue) ?? "") {
            Keychain.save(apiKey, account: provider.rawValue)
        }
    }
}

enum MCPHelper {
    /// The app binary doubles as the MCP server. Hidden in the sandboxed build, whose
    /// container MCP clients can't usefully launch into.
    static var executablePath: String? {
        ScanAccess.isSandboxed ? nil : Bundle.main.executablePath
    }

    static func claudeCodeCommand(_ path: String) -> String {
        "claude mcp add opendisk -- \"\(path)\" --mcp"
    }

    static func jsonConfig(_ path: String) -> String {
        """
        {
          "mcpServers": {
            "opendisk": { "command": "\(path)", "args": ["--mcp"] }
          }
        }
        """
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
