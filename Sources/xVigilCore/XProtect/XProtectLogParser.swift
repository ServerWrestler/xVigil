import Foundation

/// Parses `/usr/bin/log show --style ndjson` output into `XProtectLogEntry` values.
///
/// Each line of ndjson output is one JSON object per log event. Lines that are
/// not valid JSON (headers, truncation notices) are skipped.
public enum XProtectLogParser {
    /// Fields we care about from the unified log's ndjson output.
    private struct RawEntry: Decodable {
        let timestamp: String?
        let eventMessage: String?
        let processImagePath: String?
        let subsystem: String?
        let category: String?
        let messageType: String?
    }

    /// Unified log timestamps look like "2026-07-10 14:23:40.899000-0400".
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ"
        return formatter
    }()

    public static func parse(ndjson: String) -> [XProtectLogEntry] {
        ndjson.split(separator: "\n").compactMap { parseLine(String($0)) }
    }

    public static func parseLine(_ line: String) -> XProtectLogEntry? {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawEntry.self, from: data),
              let message = raw.eventMessage
        else { return nil }

        let processName = raw.processImagePath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? "unknown"

        return XProtectLogEntry(
            date: raw.timestamp.flatMap { dateFormatter.date(from: $0) },
            process: processName,
            subsystem: raw.subsystem?.isEmpty == true ? nil : raw.subsystem,
            category: raw.category?.isEmpty == true ? nil : raw.category,
            level: raw.messageType,
            message: message
        )
    }
}
