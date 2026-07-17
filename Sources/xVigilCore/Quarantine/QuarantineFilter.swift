import Foundation

/// Filter criteria for browsing the quarantine database.
public struct QuarantineFilter: Equatable, Sendable {
    /// Exact match on the downloading app's name.
    public var agentName: String?
    /// Match on the quarantine event type.
    public var kind: QuarantineEvent.Kind?
    /// Case-insensitive substring match across URLs, sender fields, and agent name.
    public var searchText: String

    public init(agentName: String? = nil, kind: QuarantineEvent.Kind? = nil, searchText: String = "") {
        self.agentName = agentName
        self.kind = kind
        self.searchText = searchText
    }
}
