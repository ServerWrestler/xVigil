import Foundation
import SQLite3

public enum QuarantineStoreError: Error, LocalizedError {
    case databaseNotFound(URL)
    case openFailed(code: Int32, message: String)
    case queryFailed(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .databaseNotFound(let url):
            "Quarantine database not found at \(url.path)"
        case .openFailed(let code, let message):
            "Could not open quarantine database (\(code)): \(message)"
        case .queryFailed(let code, let message):
            "Quarantine query failed (\(code)): \(message)"
        }
    }
}

/// Read-only access to the LaunchServices quarantine database.
///
/// Opens the database fresh for each query with `SQLITE_OPEN_READONLY` so we
/// never hold a lock against LaunchServices and always see current data.
public struct QuarantineStore: Sendable {
    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")
    }

    public let databaseURL: URL

    public init(databaseURL: URL = QuarantineStore.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    /// The most recent quarantine events, newest first.
    public func recentEvents(limit: Int = 50, since: Date? = nil) throws -> [QuarantineEvent] {
        var sql = """
            SELECT LSQuarantineEventIdentifier, LSQuarantineTimeStamp,
                   LSQuarantineAgentName, LSQuarantineAgentBundleIdentifier,
                   LSQuarantineDataURLString, LSQuarantineOriginURLString,
                   LSQuarantineSenderName, LSQuarantineSenderAddress,
                   LSQuarantineTypeNumber
            FROM LSQuarantineEvent
            """
        if since != nil {
            sql += " WHERE LSQuarantineTimeStamp >= ?"
        }
        sql += " ORDER BY LSQuarantineTimeStamp DESC LIMIT ?"

        return try withStatement(sql) { statement in
            var index: Int32 = 1
            if let since {
                sqlite3_bind_double(statement, index, since.timeIntervalSinceReferenceDate)
                index += 1
            }
            sqlite3_bind_int(statement, index, Int32(limit))

            var events: [QuarantineEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                events.append(event(from: statement))
            }
            return events
        }
    }

    /// Filtered, keyset-paginated query for browsing the full database.
    ///
    /// Pass the timestamp of the last event from the previous page as `before`
    /// to fetch the next page. Rows with a NULL timestamp are ignored once
    /// paginating (they cannot be ordered).
    public func events(
        matching filter: QuarantineFilter = QuarantineFilter(),
        before: Date? = nil,
        limit: Int = 100
    ) throws -> [QuarantineEvent] {
        var clauses: [String] = []
        var values: [SQLValue] = []

        if let agent = filter.agentName {
            clauses.append("LSQuarantineAgentName = ?")
            values.append(.text(agent))
        }
        if let kind = filter.kind, kind != .unknown {
            clauses.append("LSQuarantineTypeNumber = ?")
            values.append(.integer(kind.rawValue))
        }
        let search = filter.searchText.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            let pattern = "%" + Self.escapeLike(search) + "%"
            let columns = [
                "LSQuarantineDataURLString", "LSQuarantineOriginURLString",
                "LSQuarantineSenderName", "LSQuarantineSenderAddress",
                "LSQuarantineAgentName",
            ]
            clauses.append(
                "(" + columns.map { "\($0) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")")
            values.append(contentsOf: Array(repeating: .text(pattern), count: columns.count))
        }
        if let before {
            clauses.append("LSQuarantineTimeStamp < ?")
            values.append(.real(before.timeIntervalSinceReferenceDate))
        }

        var sql = """
            SELECT LSQuarantineEventIdentifier, LSQuarantineTimeStamp,
                   LSQuarantineAgentName, LSQuarantineAgentBundleIdentifier,
                   LSQuarantineDataURLString, LSQuarantineOriginURLString,
                   LSQuarantineSenderName, LSQuarantineSenderAddress,
                   LSQuarantineTypeNumber
            FROM LSQuarantineEvent
            """
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY LSQuarantineTimeStamp DESC LIMIT ?"
        values.append(.integer(limit))

        return try withStatement(sql) { statement in
            bind(values, to: statement)
            var events: [QuarantineEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                events.append(event(from: statement))
            }
            return events
        }
    }

    /// Distinct downloading-agent names, for filter pickers.
    public func distinctAgents() throws -> [String] {
        let sql = """
            SELECT DISTINCT LSQuarantineAgentName FROM LSQuarantineEvent
            WHERE LSQuarantineAgentName IS NOT NULL
            ORDER BY LSQuarantineAgentName COLLATE NOCASE
            """
        return try withStatement(sql) { statement in
            var agents: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let agent = columnText(statement, 0) { agents.append(agent) }
            }
            return agents
        }
    }

    /// Total number of quarantine events on record.
    public func eventCount() throws -> Int {
        try withStatement("SELECT COUNT(*) FROM LSQuarantineEvent") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// Event counts grouped by downloading agent, most active first.
    public func countsByAgent(limit: Int = 10) throws -> [(agent: String, count: Int)] {
        let sql = """
            SELECT COALESCE(LSQuarantineAgentName, 'Unknown') AS agent, COUNT(*) AS n
            FROM LSQuarantineEvent
            GROUP BY agent ORDER BY n DESC LIMIT ?
            """
        return try withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(limit))
            var rows: [(String, Int)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((columnText(statement, 0) ?? "Unknown", Int(sqlite3_column_int64(statement, 1))))
            }
            return rows
        }
    }

    // MARK: - SQLite plumbing

    private enum SQLValue {
        case text(String)
        case real(Double)
        case integer(Int)
    }

    /// SQLite must copy bound text because our Swift strings are transient.
    private static let transientDestructor = unsafeBitCast(
        -1 as Int, to: sqlite3_destructor_type.self)

    private func bind(_ values: [SQLValue], to statement: OpaquePointer) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text):
                sqlite3_bind_text(statement, index, text, -1, Self.transientDestructor)
            case .real(let double):
                sqlite3_bind_double(statement, index, double)
            case .integer(let int):
                sqlite3_bind_int64(statement, index, Int64(int))
            }
        }
    }

    /// Escapes LIKE wildcards so user input matches literally.
    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw QuarantineStoreError.databaseNotFound(databaseURL)
        }

        var db: OpaquePointer?
        let openCode = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openCode == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw QuarantineStoreError.openFailed(code: openCode, message: message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)

        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            throw QuarantineStoreError.queryFailed(code: prepareCode, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        return try body(statement)
    }

    private func event(from statement: OpaquePointer) -> QuarantineEvent {
        let rawTimestamp = sqlite3_column_type(statement, 1) == SQLITE_NULL
            ? nil : sqlite3_column_double(statement, 1)
        let rawType = sqlite3_column_type(statement, 8) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(statement, 8))

        return QuarantineEvent(
            id: columnText(statement, 0) ?? UUID().uuidString,
            timestamp: rawTimestamp.map { Date(timeIntervalSinceReferenceDate: $0) },
            agentName: columnText(statement, 2),
            agentBundleIdentifier: columnText(statement, 3),
            dataURL: columnText(statement, 4),
            originURL: columnText(statement, 5),
            senderName: columnText(statement, 6),
            senderAddress: columnText(statement, 7),
            typeNumber: rawType
        )
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        let value = String(cString: cString)
        return value.isEmpty ? nil : value
    }
}
