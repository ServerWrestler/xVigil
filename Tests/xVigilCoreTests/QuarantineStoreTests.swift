import Foundation
import SQLite3
import Testing
@testable import xVigilCore

/// Builds a throwaway quarantine database with the real production schema.
private func makeFixtureDatabase() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("xvigil-test-\(UUID().uuidString).sqlite")

    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }

    let schema = """
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
    #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)

    // Timestamps are seconds since the Core Data reference date (2001-01-01).
    let rows = """
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
    #expect(sqlite3_exec(db, rows, nil, nil, nil) == SQLITE_OK)
    return url
}

@Suite struct QuarantineStoreTests {
    @Test func readsEventsNewestFirst() throws {
        let store = QuarantineStore(databaseURL: try makeFixtureDatabase())
        let events = try store.recentEvents(limit: 10)

        #expect(events.count == 3)
        #expect(events[0].id == "AAAA-2")
        #expect(events[0].agentName == "Messages")
        #expect(events[0].kind == .messageAttachment)
        #expect(events[1].dataURL == "https://example.com/tool.dmg")
    }

    @Test func convertsCoreDataTimestamps() throws {
        let store = QuarantineStore(databaseURL: try makeFixtureDatabase())
        let events = try store.recentEvents(limit: 1)

        let expected = Date(timeIntervalSinceReferenceDate: 800_000_100)
        #expect(events[0].timestamp == expected)
    }

    @Test func respectsLimitAndSince() throws {
        let store = QuarantineStore(databaseURL: try makeFixtureDatabase())

        #expect(try store.recentEvents(limit: 2).count == 2)

        let cutoff = Date(timeIntervalSinceReferenceDate: 750_000_000)
        let recent = try store.recentEvents(limit: 10, since: cutoff)
        #expect(recent.count == 2)
        #expect(recent.allSatisfy { $0.timestamp! >= cutoff })
    }

    @Test func countsEvents() throws {
        let store = QuarantineStore(databaseURL: try makeFixtureDatabase())
        #expect(try store.eventCount() == 3)
    }

    @Test func countsByAgent() throws {
        let store = QuarantineStore(databaseURL: try makeFixtureDatabase())
        let counts = try store.countsByAgent()
        #expect(counts.count == 3)
        #expect(counts.map(\.count) == counts.map(\.count).sorted(by: >))
    }

    @Test func missingDatabaseThrows() {
        let store = QuarantineStore(databaseURL: URL(fileURLWithPath: "/nonexistent/db"))
        #expect(throws: QuarantineStoreError.self) {
            try store.recentEvents()
        }
    }

    @Test func filtersByAgent() throws {
        let store = QuarantineStore(databaseURL: try makeFixtureDatabase())
        let events = try store.events(matching: QuarantineFilter(agentName: "Chrome"))
        #expect(events.map(\.id) == ["AAAA-1"])
    }

    @Test func filtersByKind() throws {
        let store = QuarantineStore(databaseURL: try makeFixtureDatabase())
        let downloads = try store.events(matching: QuarantineFilter(kind: .webDownload))
        #expect(downloads.map(\.id) == ["AAAA-1", "AAAA-3"])
    }

    @Test func searchesAcrossColumns() throws {
        let store = QuarantineStore(databaseURL: try makeFixtureDatabase())

        let byURL = try store.events(matching: QuarantineFilter(searchText: "old.example"))
        #expect(byURL.map(\.id) == ["AAAA-3"])

        let bySender = try store.events(matching: QuarantineFilter(searchText: "jane"))
        #expect(bySender.map(\.id) == ["AAAA-2"])

        // LIKE wildcards in user input must match literally, not as wildcards.
        let literalPercent = try store.events(matching: QuarantineFilter(searchText: "%"))
        #expect(literalPercent.isEmpty)
    }

    @Test func combinesFilters() throws {
        let store = QuarantineStore(databaseURL: try makeFixtureDatabase())
        let events = try store.events(
            matching: QuarantineFilter(agentName: "Safari", kind: .webDownload))
        #expect(events.map(\.id) == ["AAAA-3"])
    }

    @Test func paginatesWithKeyset() throws {
        let store = QuarantineStore(databaseURL: try makeFixtureDatabase())

        let firstPage = try store.events(limit: 2)
        #expect(firstPage.map(\.id) == ["AAAA-2", "AAAA-1"])

        let secondPage = try store.events(before: firstPage.last?.timestamp, limit: 2)
        #expect(secondPage.map(\.id) == ["AAAA-3"])
    }

    @Test func listsDistinctAgents() throws {
        let store = QuarantineStore(databaseURL: try makeFixtureDatabase())
        #expect(try store.distinctAgents() == ["Chrome", "Messages", "Safari"])
    }

    @Test func nullColumnsBecomeNil() throws {
        let store = QuarantineStore(databaseURL: try makeFixtureDatabase())
        let messages = try store.recentEvents(limit: 10).first { $0.id == "AAAA-2" }

        #expect(messages != nil)
        #expect(messages?.dataURL == nil)
        #expect(messages?.originURL == nil)
    }
}
