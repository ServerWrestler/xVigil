import Foundation

/// A single security finding, regardless of which subsystem produced it.
/// XProtect log detections and on-demand scan hits both funnel into this so
/// the UI has one prominent surface for "something was found".
public struct Finding: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable {
        case xprotect
        case scan
        case fileMonitor

        public var label: String {
            switch self {
            case .xprotect: "XProtect"
            case .scan: "On-demand scan"
            case .fileMonitor: "File Monitor"
            }
        }
    }

    public let id: UUID
    public let source: Source
    public let date: Date?
    /// Short headline — a signature name or the flagged log line's gist.
    public let title: String
    /// Full context — the raw log message, or the infected file path.
    public let detail: String
    /// On-disk path, when the finding points at a specific file.
    public let path: String?
    /// The File Monitor entry that raised it, so the alert can be withdrawn
    /// when that entry is removed.
    public let watchlistEntryID: UUID?

    public init(
        id: UUID = UUID(),
        source: Source,
        date: Date?,
        title: String,
        detail: String,
        path: String? = nil,
        watchlistEntryID: UUID? = nil
    ) {
        self.id = id
        self.source = source
        self.date = date
        self.title = title
        self.detail = detail
        self.path = path
        self.watchlistEntryID = watchlistEntryID
    }

    /// Builds a finding from a log entry classified as a detection.
    public init(detection entry: XProtectLogEntry) {
        self.init(
            source: .xprotect,
            date: entry.date,
            title: String(entry.message.prefix(120)),
            detail: "\(entry.process): \(entry.message)"
        )
    }
}
