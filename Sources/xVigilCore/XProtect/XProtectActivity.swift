import Foundation

/// A cluster of consecutive log entries from one process — e.g. a whole
/// XProtect Remediator scan run collapsed into a single row.
public struct XProtectActivity: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let process: String
    public let entries: [XProtectLogEntry]
    public let startDate: Date?
    public let endDate: Date?
    /// Most significant kind found among the entries.
    public let kind: XProtectLogEntry.Kind

    public init(entries: [XProtectLogEntry]) {
        self.id = UUID()
        self.entries = entries
        // One logical activity (e.g. a scheduled scan run) spans several
        // cooperating processes; title it by the most talkative one.
        let processCounts = Dictionary(grouping: entries, by: \.process)
            .mapValues(\.count)
        self.process = processCounts.max {
            ($0.value, $1.key) < ($1.value, $0.key)
        }?.key ?? "unknown"
        let dates = entries.compactMap(\.date)
        self.startDate = dates.min()
        self.endDate = dates.max()
        self.kind = entries.map(\.kind).max(by: {
            $0.severityRank < $1.severityRank
        }) ?? .activity
    }

    /// Entries that made this activity interesting, for summary display.
    public var flaggedEntries: [XProtectLogEntry] {
        entries.filter { $0.kind == kind && kind != .activity }
    }
}

/// Groups a chronological entry stream into activities: a new activity starts
/// whenever the time gap exceeds `maxGap`. Process changes do NOT split a
/// cluster — one scan run interleaves entries from several cooperating
/// processes (XProtect, XProtectPluginService, …), and splitting on process
/// fragments it into noise. Entries without a parseable date inherit the
/// current cluster.
public enum XProtectActivityGrouper {
    public static func group(
        _ entries: [XProtectLogEntry],
        maxGap: TimeInterval = 30
    ) -> [XProtectActivity] {
        var activities: [XProtectActivity] = []
        var current: [XProtectLogEntry] = []
        var lastDate: Date?

        func flush() {
            if !current.isEmpty {
                activities.append(XProtectActivity(entries: current))
                current = []
            }
        }

        for entry in entries {
            if !current.isEmpty, let date = entry.date, let last = lastDate,
                date.timeIntervalSince(last) > maxGap {
                flush()
            }
            current.append(entry)
            if let date = entry.date { lastDate = date }
        }
        flush()
        return activities
    }
}
