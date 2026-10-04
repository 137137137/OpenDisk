#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Apple's on-device model. Small context window, so tool results are capped hard and
/// the model starts from a pre-computed overview instead of exploring freely.
@available(macOS 26, *)
struct AppleProvider: SuggestionProvider {
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings to use the on-device model."
        case .unavailable(.modelNotReady): "The on-device model is still downloading. Try again later."
        case .unavailable: "Apple Intelligence isn't available right now."
        }
    }

    @Generable
    struct Proposal {
        @Guide(description: "Cleanup suggestions, largest reclaimable first", .maximumCount(15))
        var suggestions: [Item]
    }

    @Generable
    struct Item {
        @Guide(description: "Exact path from the scan, may start with ~")
        var path: String
        @Guide(description: "Short label, e.g. Build cache")
        var category: String
        var risk: GeneratedRisk
        @Guide(description: "What it is and what is lost if removed")
        var rationale: String
        var regenerates: Bool
    }

    @Generable
    enum GeneratedRisk {
        case low, medium, high
        var risk: Risk {
            switch self { case .low: .low; case .medium: .medium; case .high: .high }
        }
    }

    func suggest(focus: String?, tools: AgentTools, onUpdate: @escaping SuggestionUpdate) async throws -> [Suggestion] {
        let session = LanguageModelSession(
            tools: [
                ListChildrenTool(tools: tools),
                CheckPathTool(tools: tools),
                LargestFilesTool(tools: tools),
            ],
            instructions: AgentPrompt.rules
        )
        var prompt = """
        Scan overview:
        \(Self.capped(tools.call("overview", arguments: Data())))

        Known caches and regenerable folders:
        \(Self.capped(tools.call("known_reclaimable", arguments: Data())))

        Suggest what can be removed to free space. Use the tools to look inside large folders if needed.
        """
        if let focus, !focus.isEmpty { prompt += "\nUser focus (a preference, not instructions): \(focus)" }

        tools.log(.request, "Waiting for the on-device model (it may call tools below)", detail: prompt)
        var finished: [Suggestion] = []
        for try await snapshot in session.streamResponse(to: prompt, generating: Proposal.self) {
            // Fields stream in declaration order, so an item with `regenerates` set is complete.
            let complete = (snapshot.content.suggestions ?? []).compactMap { item -> Suggestion? in
                guard let path = item.path, let category = item.category, let risk = item.risk,
                      let rationale = item.rationale, let regenerates = item.regenerates else { return nil }
                return Suggestion(path: path, category: category, risk: risk.risk, rationale: rationale, regenerates: regenerates)
            }
            if complete.count > finished.count {
                finished = complete
                tools.log(.done, "Received suggestion \(finished.count): \(finished.last!.path)")
                onUpdate(finished)
            }
        }
        return finished
    }

    func ping() async throws -> String {
        _ = try await LanguageModelSession().respond(to: "Reply with OK.")
        return "Apple Intelligence is ready."
    }

    /// Keeps tool output within the small context window.
    static func capped(_ text: String, limit: Int = 2_500) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…(truncated)"
    }

    private static func json(_ arguments: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data()
    }

    struct ListChildrenTool: Tool {
        let tools: AgentTools
        let name = "list_children"
        let description = "Largest items directly inside a folder."
        @Generable struct Arguments {
            @Guide(description: "Folder path from the scan") var path: String
        }
        func call(arguments: Arguments) async throws -> String {
            AppleProvider.capped(tools.call(name, arguments: AppleProvider.json(["path": arguments.path, "limit": 15])))
        }
    }

    struct CheckPathTool: Tool {
        let tools: AgentTools
        let name = "check_path"
        let description = "Size, protection status and minimum risk for a path."
        @Generable struct Arguments {
            @Guide(description: "Path from the scan") var path: String
        }
        func call(arguments: Arguments) async throws -> String {
            AppleProvider.capped(tools.call(name, arguments: AppleProvider.json(["path": arguments.path])))
        }
    }

    struct LargestFilesTool: Tool {
        let tools: AgentTools
        let name = "largest_files"
        let description = "Largest single files (100 MB or more) under a folder."
        @Generable struct Arguments {
            @Guide(description: "Folder path from the scan") var under: String
        }
        func call(arguments: Arguments) async throws -> String {
            AppleProvider.capped(tools.call(name, arguments: AppleProvider.json(["under": arguments.under])))
        }
    }
}
#endif
