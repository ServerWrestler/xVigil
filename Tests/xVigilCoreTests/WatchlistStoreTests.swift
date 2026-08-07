import Foundation
import Testing

@testable import xVigilCore

@Suite struct WatchlistStoreTests {
    private func makeStore() throws -> WatchlistStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xvigil-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return WatchlistStore(directory: dir)
    }

    @Test func entriesRoundTrip() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let entries = [
            WatchlistEntry(
                target: "~/Library/LaunchAgents/*.plist", label: "Agents",
                notes: "persistence", trackIntegrity: true,
                contentPatterns: ["evil\\.com"]),
            WatchlistEntry(
                target: "/usr/local/bin", label: "Local bin",
                source: .remote(url: "https://example.com/feed.json"), recursive: true),
        ]
        try store.saveEntries(entries)
        let loaded = try store.loadEntries()
        #expect(loaded == entries)
    }

    @Test func missingFilesMeanEmptyNotError() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(try store.loadEntries().isEmpty)
        #expect(try store.loadState().isEmpty)
    }

    @Test func stateRoundTripAndPruning() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let kept = WatchlistEntry(target: "/a", label: "kept")
        let removed = WatchlistEntry(target: "/b", label: "removed")
        let state: [UUID: WatchlistCheckState] = [
            kept.id: WatchlistCheckState(
                lastChecked: Date(), baselineHashes: ["/a": "abc123"]),
            removed.id: WatchlistCheckState(baselineHashes: ["/b": "def456"]),
        ]

        // Saving with only `kept` in the entry list prunes `removed`'s state.
        try store.saveState(state, keeping: [kept])
        let loaded = try store.loadState()
        #expect(loaded.count == 1)
        #expect(loaded[kept.id]?.baselineHashes == ["/a": "abc123"])
        #expect(loaded[removed.id] == nil)
    }

    @Test func mergeReplacesRemotePreservesLocal() {
        let local = WatchlistEntry(target: "/mine", label: "mine")
        let oldRemote = WatchlistEntry(
            target: "/old", label: "old feed entry",
            source: .remote(url: "https://feed.example/w.json"))
        let newRemote = WatchlistEntry(
            target: "/new", label: "new feed entry",
            source: .remote(url: "https://feed.example/w.json"))

        let merged = WatchlistStore.merge(
            remote: [newRemote], into: [local, oldRemote])
        #expect(merged.contains(local))
        #expect(merged.contains(newRemote))
        #expect(!merged.contains(oldRemote))
    }

    @Test func mergeCollisionLocalWins() {
        let sharedID = UUID()
        let local = WatchlistEntry(id: sharedID, target: "/mine", label: "local version")
        let remote = WatchlistEntry(
            id: sharedID, target: "/theirs", label: "remote version",
            source: .remote(url: "https://feed.example/w.json"))

        let merged = WatchlistStore.merge(remote: [remote], into: [local])
        #expect(merged.count == 1)
        #expect(merged[0].label == "local version")
    }

    @Test func mergeDeduplicatesRemoteByID() {
        let sharedID = UUID()
        let first = WatchlistEntry(
            id: sharedID, target: "/a", label: "first",
            source: .remote(url: "https://feed.example/w.json"))
        let duplicate = WatchlistEntry(
            id: sharedID, target: "/b", label: "duplicate",
            source: .remote(url: "https://feed.example/w.json"))

        let merged = WatchlistStore.merge(remote: [first, duplicate], into: [])
        #expect(merged.count == 1)
        #expect(merged[0].label == "first")
    }

    /// The reason for the config/state split: a remote refresh must not
    /// destroy integrity baselines for feed entries that persist.
    @Test func stateSurvivesMerge() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let feedEntryID = UUID()
        let feedURL = "https://feed.example/w.json"
        let v1 = WatchlistEntry(
            id: feedEntryID, target: "/watched", label: "v1",
            source: .remote(url: feedURL), trackIntegrity: true)
        try store.saveEntries([v1])
        try store.saveState(
            [feedEntryID: WatchlistCheckState(baselineHashes: ["/watched": "abc"])],
            keeping: [v1])

        // Fetch delivers an updated copy of the same entry (same ID).
        let v2 = WatchlistEntry(
            id: feedEntryID, target: "/watched", label: "v2 renamed",
            source: .remote(url: feedURL), trackIntegrity: true)
        let merged = WatchlistStore.merge(remote: [v2], into: try store.loadEntries())
        try store.saveEntries(merged)
        try store.saveState(try store.loadState(), keeping: merged)

        // Baseline for the persisting entry is intact after the refresh.
        let state = try store.loadState()
        #expect(state[feedEntryID]?.baselineHashes == ["/watched": "abc"])
    }

    @Test func decodeAppliesAlertConditionDefaults() throws {
        // A hand-written / feed entry omitting alertConditions gets the
        // documented defaults (plain entry ⇒ alert when found).
        let json = """
            {"version": 1, "entries": [
              {"id": "550E8400-E29B-41D4-A716-446655440000",
               "target": "/Library/LaunchDaemons/com.malware.helper.plist",
               "label": "Known-bad plist",
               "source": {"type": "local"}},
              {"target": "/etc/hosts", "label": "hosts", "trackIntegrity": true}
            ]}
            """
        let file = try WatchlistStore.decoder()
            .decode(WatchlistFile.self, from: Data(json.utf8))
        #expect(file.entries[0].alertConditions == [.onPresence])
        #expect(file.entries[1].alertConditions == [.onChange])
        // Omitted optional fields default sanely too.
        #expect(file.entries[1].source == .local)
        #expect(file.entries[1].recursive == false)
    }
}
