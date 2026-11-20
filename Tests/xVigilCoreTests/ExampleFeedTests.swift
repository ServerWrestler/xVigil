import Foundation
import Testing

@testable import xVigilCore

/// Checks feeds/macos-persistence-example.json with the app's own code:
/// the fetcher's decoder and limits, ICU regexes (NSRegularExpression), the
/// checker's content scanner, and its glob resolver. The Python scripts
/// approximate these; this suite is the authoritative check.
@Suite struct ExampleFeedTests {
    private static let feedsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // xVigilCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("feeds")

    private static func feedData() throws -> Data {
        try Data(contentsOf: feedsDirectory
            .appendingPathComponent("macos-persistence-example.json"))
    }

    private static func entries() throws -> [WatchlistEntry] {
        try WatchlistStore.decoder().decode(WatchlistFile.self, from: feedData()).entries
    }

    private struct Samples: Decodable {
        struct Group: Decodable {
            var name: String
            var entries: [String]
            var match: [String]
            var noMatch: [String]
        }
        struct Glob: Decodable {
            var entry: String
            var file: String
            var resolves: Bool
        }
        var contentGroups: [Group]
        var globs: [Glob]
    }

    private static func samples() throws -> Samples {
        let data = try Data(contentsOf: feedsDirectory
            .appendingPathComponent("samples/macos-persistence-example.json"))
        return try JSONDecoder().decode(Samples.self, from: data)
    }

    private static func select(_ prefixes: [String], from entries: [WatchlistEntry])
        -> [WatchlistEntry]
    {
        entries.filter { entry in prefixes.contains { entry.label.hasPrefix($0) } }
    }

    @Test func decodesAndPassesFetcherLimits() throws {
        let file = try WatchlistStore.decoder().decode(WatchlistFile.self, from: Self.feedData())
        #expect(file.version == 1)
        #expect(!file.entries.isEmpty)
        try WatchlistFetcher.validate(file.entries)
    }

    @Test func idsAreExplicitAndUnique() throws {
        // A missing id decodes to a fresh random UUID on every fetch, which
        // would discard integrity baselines, so require one in the JSON.
        let raw = try #require(
            try JSONSerialization.jsonObject(with: Self.feedData()) as? [String: Any])
        let rawEntries = try #require(raw["entries"] as? [[String: Any]])
        for entry in rawEntries {
            #expect(entry["id"] is String, "entry without id: \(entry["label"] ?? "?")")
            // The fetcher overrides source anyway; a feed setting it is a mistake.
            #expect(entry["source"] == nil, "feed sets source: \(entry["label"] ?? "?")")
        }
        let ids = try Self.entries().map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func entriesAreInternallyConsistent() throws {
        for entry in try Self.entries() {
            #expect(!entry.alertConditions.isEmpty, "\(entry.label)")
            if entry.alertConditions.contains(.onMatch) {
                #expect(!entry.contentPatterns.isEmpty, "onMatch without patterns: \(entry.label)")
            }
            if entry.alertConditions.contains(.onChange) {
                #expect(entry.trackIntegrity, "onChange without integrity: \(entry.label)")
            }
        }
    }

    @Test func everyPatternCompilesWithICU() throws {
        for entry in try Self.entries() {
            for pattern in entry.contentPatterns {
                #expect(
                    (try? NSRegularExpression(pattern: pattern)) != nil,
                    "\(entry.label): \(pattern)")
            }
        }
    }

    @Test func contentSamplesMatchAsExpected() throws {
        let entries = try Self.entries()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xvigil-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var covered = Set<UUID>()
        for group in try Self.samples().contentGroups {
            let selected = Self.select(group.entries, from: entries)
                .filter { !$0.contentPatterns.isEmpty }
            #expect(!selected.isEmpty, "group \(group.name) selects no entries")
            for entry in selected {
                covered.insert(entry.id)
                let regexes = try entry.contentPatterns.map {
                    (pattern: $0, regex: try NSRegularExpression(pattern: $0))
                }
                for (sample, expected) in group.match.map({ ($0, true) })
                    + group.noMatch.map({ ($0, false) })
                {
                    let file = directory.appendingPathComponent(UUID().uuidString)
                    try sample.write(to: file, atomically: true, encoding: .utf8)
                    let (matched, error) = WatchlistChecker.scanContent(
                        atPath: file.path, regexes: regexes)
                    #expect(error == nil)
                    #expect(
                        !matched.isEmpty == expected,
                        "\(entry.label): \(expected ? "missed" : "false positive on") \(sample.debugDescription)")
                }
            }
        }
        for entry in entries where !entry.contentPatterns.isEmpty {
            #expect(covered.contains(entry.id), "no samples for \(entry.label)")
        }
    }

    @Test func globSamplesResolveAsExpected() throws {
        let entries = try Self.entries()
        for sample in try Self.samples().globs {
            let selected = Self.select([sample.entry], from: entries)
            #expect(!selected.isEmpty, "no entry for \(sample.entry)")
            for entry in selected {
                // Resolve the entry's own glob in a temp directory holding
                // only the sample file.
                let pattern = WatchlistChecker.splitGlob(
                    (entry.target as NSString).expandingTildeInPath).pattern
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("xvigil-glob-\(UUID().uuidString)")
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                try Data().write(to: directory.appendingPathComponent(sample.file))

                let resolved = WatchlistChecker.resolve(
                    target: directory.path + "/" + pattern, recursive: entry.recursive)
                #expect(
                    !resolved.paths.isEmpty == sample.resolves,
                    "\(entry.target) vs \(sample.file): want \(sample.resolves)")
            }
        }
    }
}
