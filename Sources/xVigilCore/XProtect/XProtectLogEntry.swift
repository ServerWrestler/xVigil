import Foundation

/// One entry from the unified log relevant to XProtect / Gatekeeper activity.
public struct XProtectLogEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let date: Date?
    public let process: String
    public let subsystem: String?
    public let category: String?
    /// Unified log message type: Default, Info, Debug, Error, Fault.
    public let level: String?
    public let message: String

    public init(
        id: UUID = UUID(),
        date: Date?,
        process: String,
        subsystem: String?,
        category: String?,
        level: String?,
        message: String
    ) {
        self.id = id
        self.date = date
        self.process = process
        self.subsystem = subsystem
        self.category = category
        self.level = level
        self.message = message
    }

    /// Rough classification of what this entry represents.
    public var kind: Kind {
        let lowered = message.lowercased()
        if lowered.contains("malware") || lowered.contains("detected")
            || lowered.contains("remediat") || lowered.contains("yara") {
            return .detection
        }
        if lowered.contains("assessment") || lowered.contains("gatekeeper") {
            return .assessment
        }
        if lowered.contains("scan") {
            return .scan
        }
        return .activity
    }

    public enum Kind: String, Sendable {
        /// Possible detection or remediation event — the interesting ones.
        case detection
        /// Gatekeeper / syspolicyd assessment of a binary.
        case assessment
        /// XProtect Remediator scan activity.
        case scan
        /// Routine service chatter.
        case activity
    }
}
