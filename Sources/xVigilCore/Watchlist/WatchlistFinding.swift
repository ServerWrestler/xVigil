import Foundation

/// Result of checking a single resolved file path for a watchlist entry.
public struct WatchlistFinding: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let path: String
    public let exists: Bool
    /// Integrity result: `true`/`false` on compare against a prior baseline,
    /// `nil` when integrity isn't tracked or this is the first sighting
    /// (a first baseline is not a change).
    public let hashChanged: Bool?
    /// Which content regexes matched; empty = none (or no content scan).
    public let matchedPatterns: [String]
    /// Per-file problem (permission denied, too large, invalid pattern,
    /// scan timeout, truncation). Never aborts the entry or the pass.
    public let error: String?
    /// True when this finding satisfies any of the entry's alertConditions.
    /// Computed by the checker; drives promotion to DetectionMonitor.
    public let isAlert: Bool

    public init(
        id: UUID = UUID(),
        path: String,
        exists: Bool,
        hashChanged: Bool? = nil,
        matchedPatterns: [String] = [],
        error: String? = nil,
        isAlert: Bool = false
    ) {
        self.id = id
        self.path = path
        self.exists = exists
        self.hashChanged = hashChanged
        self.matchedPatterns = matchedPatterns
        self.error = error
        self.isAlert = isAlert
    }

    /// Short human-readable reason list ("found", "changed", "matched: x").
    public var reasons: [String] {
        var reasons: [String] = []
        if exists { reasons.append("found") } else { reasons.append("missing") }
        if hashChanged == true { reasons.append("changed") }
        if !matchedPatterns.isEmpty {
            reasons.append("matched: " + matchedPatterns.joined(separator: ", "))
        }
        if let error { reasons.append(error) }
        return reasons
    }
}
