import Foundation

/// The model Find More uses. OpenDisk's known caches are always shown without one.
enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case apple, anthropic, openAICompatible
    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple Intelligence (on-device)"
        case .anthropic: "Anthropic (your API key)"
        case .openAICompatible: "OpenAI-compatible (your API key)"
        }
    }

    /// What actually does the work: the configured model, or Apple Intelligence.
    var shortTitle: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .anthropic: AISettings.anthropicModel
        case .openAICompatible: AISettings.openAIModel
        }
    }

    var sendsDataOffDevice: Bool { self != .apple }

    var disclaimer: String {
        switch self {
        case .apple:
            "On-device model: small and may be wrong. Review every suggestion. Risk ratings are enforced by OpenDisk rules, not the model."
        case .anthropic, .openAICompatible:
            "AI suggestions can be wrong. Review every item. OpenDisk drops protected paths and can only raise a risk rating, never lower it."
        }
    }
}

/// UserDefaults keys; read with @AppStorage in views and these accessors elsewhere.
enum AISettings {
    static let providerKey = "ai_provider"
    static let redactKey = "ai_redact_home"
    static let anthropicModelKey = "ai_anthropic_model"
    static let openAIModelKey = "ai_openai_model"
    static let openAIBaseURLKey = "ai_openai_base_url"
    static let consentKeyPrefix = "ai_consent_"

    static let defaultAnthropicModel = "claude-sonnet-5-5"
    static let defaultOpenAIModel = "gpt-4o-mini"
    static let defaultOpenAIBaseURL = "https://api.openai.com/v1"

    private static var defaults: UserDefaults { .standard }

    static var redactHome: Bool { defaults.object(forKey: redactKey) as? Bool ?? true }
    static var anthropicModel: String { nonEmpty(anthropicModelKey) ?? defaultAnthropicModel }
    static var openAIModel: String { nonEmpty(openAIModelKey) ?? defaultOpenAIModel }
    static var openAIBaseURL: String { nonEmpty(openAIBaseURLKey) ?? defaultOpenAIBaseURL }

    static func hasConsent(for provider: AIProvider) -> Bool {
        !provider.sendsDataOffDevice || defaults.bool(forKey: consentKeyPrefix + provider.rawValue)
    }
    static func grantConsent(for provider: AIProvider) {
        defaults.set(true, forKey: consentKeyPrefix + provider.rawValue)
    }

    private static func nonEmpty(_ key: String) -> String? {
        defaults.string(forKey: key).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }
}

/// Learns how long an analysis usually takes per provider and model, for the ETA.
enum AIDurationEstimate {
    private static func key(_ provider: AIProvider) -> String {
        "ai_duration_\(provider.rawValue)_\(provider.shortTitle)"
    }

    static func expected(for provider: AIProvider) -> TimeInterval? {
        let value = UserDefaults.standard.double(forKey: key(provider))
        return value > 0 ? value : nil
    }

    /// Exponential moving average, so recent runs count most without one outlier dominating.
    static func record(_ duration: TimeInterval, for provider: AIProvider) {
        let next = expected(for: provider).map { $0 * 0.6 + duration * 0.4 } ?? duration
        UserDefaults.standard.set(next, forKey: key(provider))
    }
}
