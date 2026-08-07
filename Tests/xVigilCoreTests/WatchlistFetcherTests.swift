import Foundation
import Testing

@testable import xVigilCore

@Suite struct WatchlistFetcherTests {
    @Test func decodesValidFeed() throws {
        let json = """
            {"version": 1, "entries": [
              {"target": "/Library/LaunchDaemons/bad.plist", "label": "Bad plist"}
            ]}
            """
        let file = try WatchlistStore.decoder()
            .decode(WatchlistFile.self, from: Data(json.utf8))
        try WatchlistFetcher.validate(file.entries)
        #expect(file.entries.count == 1)
    }

    @Test func rejectsMalformedJSON() {
        #expect(throws: (any Error).self) {
            try WatchlistStore.decoder()
                .decode(WatchlistFile.self, from: Data("not json".utf8))
        }
    }

    @Test func rejectsNonHTTPSURL() async {
        let fetcher = WatchlistFetcher()
        await #expect(throws: WatchlistFetchError.insecureURL("http://example.com/w.json")) {
            _ = try await fetcher.fetch(from: URL(string: "http://example.com/w.json")!)
        }
    }

    @Test func rejectsOversizedFeeds() {
        let flood = (0...WatchlistFetcher.maxEntries).map {
            WatchlistEntry(target: "/f\($0)", label: "e\($0)")
        }
        #expect(throws: WatchlistFetchError.tooManyEntries(
            count: flood.count, limit: WatchlistFetcher.maxEntries)) {
            try WatchlistFetcher.validate(flood)
        }
    }

    @Test func rejectsTooManyPatterns() {
        let entry = WatchlistEntry(
            target: "/a", label: "patterns",
            contentPatterns: (0...WatchlistFetcher.maxPatternsPerEntry).map { "p\($0)" })
        #expect(throws: WatchlistFetchError.tooManyPatterns(
            entry: "patterns", count: entry.contentPatterns.count,
            limit: WatchlistFetcher.maxPatternsPerEntry)) {
            try WatchlistFetcher.validate([entry])
        }
    }

    @Test func rejectsOversizedPattern() {
        let long = String(repeating: "a", count: WatchlistFetcher.maxPatternLength + 1)
        let entry = WatchlistEntry(target: "/a", label: "long", contentPatterns: [long])
        #expect(throws: WatchlistFetchError.patternTooLong(
            entry: "long", length: long.count,
            limit: WatchlistFetcher.maxPatternLength)) {
            try WatchlistFetcher.validate([entry])
        }
    }
}
