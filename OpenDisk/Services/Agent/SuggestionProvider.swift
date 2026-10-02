import Foundation

/// Called with the full list of suggestions so far each time it grows, so results can be
/// shown while the model is still working.
typealias SuggestionUpdate = @Sendable ([Suggestion]) -> Void

protocol SuggestionProvider: Sendable {
    /// Returns raw suggestions; callers always pass them through `AgentTools.validate`.
    func suggest(focus: String?, tools: AgentTools, onUpdate: @escaping SuggestionUpdate) async throws -> [Suggestion]
    /// Minimal request with no scan data, for Settings › Test Connection. Returns a success message.
    func ping() async throws -> String
}

/// Accumulates incremental `propose` calls, later entries replacing earlier ones by path.
struct ProposalAccumulator {
    private(set) var suggestions: [Suggestion] = []

    mutating func add(_ new: [Suggestion]) {
        for suggestion in new {
            let key = SuggestionValidator.expand(suggestion.path)
            if let index = suggestions.firstIndex(where: { SuggestionValidator.expand($0.path) == key }) {
                suggestions[index] = suggestion
            } else {
                suggestions.append(suggestion)
            }
        }
    }
}

enum SuggestionError: LocalizedError {
    case missingAPIKey
    case noProposal
    case http(Int, String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add an API key in Settings › AI."
        case .noProposal: "The model finished without making suggestions. Try again or rephrase the focus."
        case .http(let code, let body): "The AI service returned \(code): \(body.prefix(300))"
        case .unavailable(let reason): reason
        }
    }
}

extension AIProvider {
    func makeProvider() throws -> any SuggestionProvider {
        switch self {
        case .anthropic:
            guard let key = Keychain.read(account: rawValue) else { throw SuggestionError.missingAPIKey }
            return AnthropicProvider(apiKey: key, model: AISettings.anthropicModel)
        case .openAICompatible:
            // The key is optional: local and LAN servers (Ollama, LM Studio, LiteLLM) often have none.
            return OpenAICompatibleProvider(
                apiKey: Keychain.read(account: rawValue) ?? "",
                model: AISettings.openAIModel, baseURL: AISettings.openAIBaseURL
            )
        case .apple:
            if let reason = Self.appleUnavailableReason { throw SuggestionError.unavailable(reason) }
            #if canImport(FoundationModels)
            if #available(macOS 26, *) { return AppleProvider() }
            #endif
            throw SuggestionError.unavailable("Apple Intelligence isn't available.")
        }
    }

    /// Why the on-device model can't be used right now, or nil when it can.
    static var appleUnavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return AppleProvider.unavailableReason }
        #endif
        return "Apple Intelligence needs macOS 26 or later."
    }
}

extension Suggestion {
    /// A catalog hit from `AgentTools.knownReclaimable()`, shown before (or without) any AI.
    init(_ item: AgentTools.Reclaimable) {
        self.init(
            path: item.path,
            category: item.name,
            risk: .low,
            rationale: item.regenerates
                ? "\(item.name) is rebuilt automatically when needed. Removing it frees space; the next build or install may be slower."
                : "Items you've already moved to the Trash.",
            regenerates: item.regenerates
        )
    }
}
