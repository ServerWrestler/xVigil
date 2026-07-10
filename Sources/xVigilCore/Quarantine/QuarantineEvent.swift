import Foundation

/// One row from the LaunchServices quarantine database
/// (`~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2`).
public struct QuarantineEvent: Identifiable, Hashable, Sendable {
    /// LSQuarantineEventIdentifier (UUID string).
    public let id: String
    /// When the file was quarantined. Stored on disk as seconds since the
    /// Core Data reference date (2001-01-01).
    public let timestamp: Date?
    /// Human-readable name of the app that downloaded the file (e.g. "Chrome").
    public let agentName: String?
    /// Bundle identifier of the downloading app.
    public let agentBundleIdentifier: String?
    /// URL the file data was fetched from.
    public let dataURL: String?
    /// Page or context the download originated from.
    public let originURL: String?
    /// Sender name for mail/message attachments.
    public let senderName: String?
    /// Sender address for mail/message attachments.
    public let senderAddress: String?
    /// Raw LSQuarantineTypeNumber value.
    public let typeNumber: Int?

    public init(
        id: String,
        timestamp: Date?,
        agentName: String?,
        agentBundleIdentifier: String?,
        dataURL: String?,
        originURL: String?,
        senderName: String?,
        senderAddress: String?,
        typeNumber: Int?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.agentName = agentName
        self.agentBundleIdentifier = agentBundleIdentifier
        self.dataURL = dataURL
        self.originURL = originURL
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.typeNumber = typeNumber
    }

    /// Decoded quarantine event type.
    public var kind: Kind { Kind(rawValue: typeNumber ?? -1) ?? .unknown }

    public enum Kind: Int, Sendable, CaseIterable {
        case webDownload = 0
        case otherDownload = 1
        case emailAttachment = 2
        case messageAttachment = 3
        case calendarEventAttachment = 4
        case otherAttachment = 5
        case unknown = -1

        public var label: String {
            switch self {
            case .webDownload: "Web download"
            case .otherDownload: "Download"
            case .emailAttachment: "Email attachment"
            case .messageAttachment: "Message attachment"
            case .calendarEventAttachment: "Calendar attachment"
            case .otherAttachment: "Attachment"
            case .unknown: "Unknown"
            }
        }
    }
}
