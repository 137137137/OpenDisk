import Foundation

enum Risk: String, Codable, Sendable, CaseIterable, Comparable {
    case low, medium, high
    static func < (a: Risk, b: Risk) -> Bool { a.order < b.order }
    private var order: Int { Risk.allCases.firstIndex(of: self)! }
}

/// What a model (or the rule engine) proposes. Untrusted until validated.
struct Suggestion: Codable, Sendable, Hashable {
    var path: String
    var category: String
    var risk: Risk
    var rationale: String
    var regenerates: Bool
    var howToRemove: String?
}

/// A suggestion after `SuggestionValidator`: real path, size from the scan, enforced risk.
struct ValidatedSuggestion: Sendable, Hashable, Identifiable {
    var suggestion: Suggestion
    var path: String
    var size: Int64
    var isDirectory: Bool
    var risk: Risk
    /// Set when OpenDisk's rules raised the model's rating.
    var riskRaisedReason: String?
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct RejectedSuggestion: Sendable, Hashable, Identifiable {
    var path: String
    var reason: String
    var id: String { path + reason }
}

struct SuggestionReport: Sendable {
    var accepted: [ValidatedSuggestion]
    var rejected: [RejectedSuggestion]
}
