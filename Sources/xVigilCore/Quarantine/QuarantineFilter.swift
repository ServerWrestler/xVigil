import Foundation

/// Filter criteria for browsing the quarantine database.
public struct QuarantineFilter: Equatable, Sendable {
    /// Exact match on the downloading app's name.
    public var agentName: String?
    /// Exact match on the raw LSQuarantineTypeNumber. Raw rather than
    /// `QuarantineEvent.Kind` so undocumented types (e.g. GarageBand's
    /// type 7) are filterable too — the UI builds its options from the
    /// type numbers actually present in the database.
    public var typeNumber: Int?
    /// Case-insensitive substring match across URLs, sender fields, and agent name.
    public var searchText: String

    public init(agentName: String? = nil, typeNumber: Int? = nil, searchText: String = "") {
        self.agentName = agentName
        self.typeNumber = typeNumber
        self.searchText = searchText
    }
}
