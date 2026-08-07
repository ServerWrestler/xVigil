import Foundation

/// Mutable per-entry check state, kept separate from `WatchlistEntry` so
/// (a) remote refreshes never clobber integrity baselines and (b) entries
/// stay value-stable for list identity. Persisted keyed by entry ID.
public struct WatchlistCheckState: Codable, Sendable, Equatable {
    public var lastChecked: Date?
    /// Integrity baselines: resolved absolute path → SHA-256 hex digest.
    /// A dictionary, not a single hash — one entry (glob/recursive dir)
    /// can resolve to many files, each needing its own baseline.
    public var baselineHashes: [String: String]
    public var findings: [WatchlistFinding]

    public init(
        lastChecked: Date? = nil,
        baselineHashes: [String: String] = [:],
        findings: [WatchlistFinding] = []
    ) {
        self.lastChecked = lastChecked
        self.baselineHashes = baselineHashes
        self.findings = findings
    }
}
