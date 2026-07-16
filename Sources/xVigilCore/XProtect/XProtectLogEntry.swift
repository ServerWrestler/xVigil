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
    public var kind: Kind { Kind.classify(message) }

    public enum Kind: String, Sendable, Hashable {
        /// Possible detection or remediation event — the interesting ones.
        case detection
        /// Gatekeeper / syspolicyd assessment of a binary.
        case assessment
        /// XProtect Remediator scan activity.
        case scan
        /// Routine service chatter.
        case activity

        /// Higher is more significant; used to summarize activity clusters.
        public var severityRank: Int {
            switch self {
            case .detection: 3
            case .assessment: 2
            case .scan: 1
            case .activity: 0
            }
        }

        public var label: String {
            switch self {
            case .detection: "Possible detection"
            case .assessment: "Gatekeeper assessment"
            case .scan: "Scan activity"
            case .activity: "Service activity"
            }
        }

        /// Threat-shaped language. Requires an actual threat noun or a
        /// "threats found"-style verb phrase — a bare "detected" matches too
        /// much routine chatter ("no new updates detected", …).
        nonisolated(unsafe) private static let threatPattern =
            /\b(malware|trojan|adware|spyware|virus|infected|infection|yara)\b|threats? (found|detected)|remediation (succeeded|performed|complete)|detected xprotect\./

        /// Phrases that flip threat language into an all-clear.
        private static let negationPhrases = [
            "no threat", "not detected", "nothing detected", "0 threats",
            "no malware", "no infected",
        ]

        public static func classify(_ message: String) -> Kind {
            let lowered = message.lowercased()
            let negated = negationPhrases.contains { lowered.contains($0) }
            if !negated, lowered.firstMatch(of: threatPattern) != nil {
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
    }
}
