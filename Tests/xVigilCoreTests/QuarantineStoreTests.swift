import Foundation
import SQLite3
import Testing
@testable import xVigilCore

/// The production schema, verbatim.
private let fixtureSchema = """
    CREATE TABLE LSQuarantineEvent (
        LSQuarantineEventIdentifier TEXT PRIMARY KEY NOT NULL,
        LSQuarantineTimeStamp REAL,
        LSQuarantineAgentBundleIdentifier TEXT,
        LSQuarantineAgentName TEXT,
        LSQuarantineDataURLString TEXT,
        LSQuarantineSenderName TEXT,
        LSQuarantineSenderAddress TEXT,
        LSQuarantineTypeNumber INTEGER,
        LSQuarantineOriginTitle TEXT,
        LSQuarantineOriginURLString TEXT,
        LSQuarantineOriginAlias BLOB
    );
    """

/// Timestamps are seconds since the Core Data reference date (2001-01-01).
private let defaultRows = """
    INSERT INTO LSQuarantineEvent
        (LSQuarantineEventIdentifier, LSQuarantineTimeStamp, LSQuarantineAgentName,
         LSQuarantineAgentBundleIdentifier, LSQuarantineDataURLString,
         LSQuarantineOriginURLString, LSQuarantineSenderName, LSQuarantineTypeNumber)
    VALUES
        ('AAAA-1', 800000000.0, 'Chrome', 'com.google.Chrome',
         'https://example.com/tool.dmg', 'https://example.com/downloads', NULL, 0),
        ('AAAA-2', 800000100.0, 'Messages', 'com.apple.MobileSMS',
         NULL, NULL, 'Jane Doe', 3),
        ('AAAA-3', 700000000.0, 'Safari', 'com.apple.Safari',
         'https://old.example.com/a.zip', NULL, NULL, 0);
    """

/// Builds a throwaway quarantine database, runs `body` against a store on it,
/// and always removes the file afterward.
private func withStore<T>(
    rows: String = defaultRows,
    _ body: (QuarantineStore) throws -> T
) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("xvigil-test-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, fixtureSchema, nil, nil, nil) == SQLITE_OK)
    #expect(sqlite3_exec(db, rows, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    return try body(QuarantineStore(databaseURL: url))
}

@Suite struct QuarantineStoreTests {
    @Test func readsEventsNewestFirst() throws {
        try withStore { store in
            let events = try store.recentEvents(limit: 10)
            #expect(events.count == 3)
            #expect(events[0].id == "AAAA-2")
            #expect(events[0].agentName == "Messages")
            #expect(events[0].kind == .messageAttachment)
            #expect(events[1].dataURL == "https://example.com/tool.dmg")
        }
    }

    @Test func convertsCoreDataTimestamps() throws {
        try withStore { store in
            let events = try store.recentEvents(limit: 1)
            #expect(events[0].timestamp == Date(timeIntervalSinceReferenceDate: 800_000_100))
        }
    }

    @Test func respectsLimit() throws {
        try withStore { store in
            let events = try store.recentEvents(limit: 2)
            #expect(events.count == 2)
        }
    }

    @Test func looksUpSingleEventByID() throws {
        try withStore { store in
            let event = try store.event(id: "AAAA-2")
            #expect(event?.agentName == "Messages")
            let missing = try store.event(id: "NOPE")
            #expect(missing == nil)
        }
    }

    @Test func filtersByAgent() throws {
        try withStore { store in
            let events = try store.events(matching: QuarantineFilter(agentName: "Chrome"))
            #expect(events.map(\.id) == ["AAAA-1"])
        }
    }

    @Test func filtersByKind() throws {
        try withStore { store in
            let downloads = try store.events(matching: QuarantineFilter(kind: .webDownload))
            #expect(downloads.map(\.id) == ["AAAA-1", "AAAA-3"])
        }
    }

    @Test func searchesAcrossColumns() throws {
        try withStore { store in
            let byURL = try store.events(matching: QuarantineFilter(searchText: "old.example"))
            #expect(byURL.map(\.id) == ["AAAA-3"])

            let bySender = try store.events(matching: QuarantineFilter(searchText: "jane"))
            #expect(bySender.map(\.id) == ["AAAA-2"])

            // LIKE wildcards in user input must match literally, not as wildcards.
            let literalPercent = try store.events(matching: QuarantineFilter(searchText: "%"))
            #expect(literalPercent.isEmpty)
        }
    }

    @Test func combinesFilters() throws {
        try withStore { store in
            let events = try store.events(
                matching: QuarantineFilter(agentName: "Safari", kind: .webDownload))
            #expect(events.map(\.id) == ["AAAA-3"])
        }
    }

    @Test func paginatesWithKeyset() throws {
        try withStore { store in
            let firstPage = try store.events(limit: 2)
            #expect(firstPage.map(\.id) == ["AAAA-2", "AAAA-1"])

            let secondPage = try store.events(before: firstPage.last, limit: 2)
            #expect(secondPage.map(\.id) == ["AAAA-3"])
        }
    }

    @Test func paginatesThroughDuplicateTimestampsWithoutLoss() throws {
        // Batch downloads share one timestamp; the composite (timestamp, id)
        // cursor must not drop rows when a page boundary lands mid-batch.
        let rows = """
            INSERT INTO LSQuarantineEvent
                (LSQuarantineEventIdentifier, LSQuarantineTimeStamp,
                 LSQuarantineAgentName, LSQuarantineTypeNumber)
            VALUES
                ('BBBB-1', 900000000.0, 'Chrome', 0),
                ('BBBB-2', 900000000.0, 'Chrome', 0),
                ('BBBB-3', 900000000.0, 'Chrome', 0),
                ('BBBB-4', 800000000.0, 'Safari', 0);
            """
        try withStore(rows: rows) { store in
            var seen: [String] = []
            var cursor: QuarantineEvent?
            while true {
                let page = try store.events(before: cursor, limit: 2)
                if page.isEmpty { break }
                seen.append(contentsOf: page.map(\.id))
                cursor = page.last
            }
            #expect(seen.sorted() == ["BBBB-1", "BBBB-2", "BBBB-3", "BBBB-4"])
            #expect(seen.count == Set(seen).count)
        }
    }

    @Test func countsEvents() throws {
        try withStore { store in
            let count = try store.eventCount()
            #expect(count == 3)
        }
    }

    @Test func listsDistinctAgents() throws {
        try withStore { store in
            let agents = try store.distinctAgents()
            #expect(agents == ["Chrome", "Messages", "Safari"])
        }
    }

    @Test func countsByAgent() throws {
        try withStore { store in
            let counts = try store.countsByAgent()
            #expect(counts.count == 3)
            #expect(counts.map(\.count) == counts.map(\.count).sorted(by: >))
        }
    }

    @Test func missingDatabaseThrows() {
        let store = QuarantineStore(databaseURL: URL(fileURLWithPath: "/nonexistent/db"))
        #expect(throws: QuarantineStoreError.self) {
            try store.recentEvents()
        }
    }

    @Test func nullColumnsBecomeNil() throws {
        try withStore { store in
            let messages = try store.recentEvents(limit: 10).first { $0.id == "AAAA-2" }
            #expect(messages != nil)
            #expect(messages?.dataURL == nil)
            #expect(messages?.originURL == nil)
        }
    }
}