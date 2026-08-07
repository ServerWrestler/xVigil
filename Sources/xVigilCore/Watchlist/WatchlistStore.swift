import Foundation

public enum WatchlistStoreError: Error, LocalizedError {
    case readFailed(URL, String)
    case writeFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let url, let message):
            "Could not read \(url.lastPathComponent): \(message)"
        case .writeFailed(let url, let message):
            "Could not write \(url.lastPathComponent): \(message)"
        }
    }
}

/// On-disk shape of watchlist.json — also the shape remote feeds serve,
/// so the fetcher decodes the same type.
struct WatchlistFile: Codable {
    var version: Int
    var entries: [WatchlistEntry]
}

/// Local persistence for the watchlist: entry configuration and per-entry
/// check state live in separate JSON files, so a remote refresh (which
/// rewrites entries) never touches integrity baselines.
///
///     <directory>/watchlist.json        — entries (config)
///     <directory>/watchlist-state.json  — check state keyed by entry ID
///
/// JSON is pretty-printed with sorted keys and ISO-8601 dates: the local
/// file is meant to be hand-editable.
public struct WatchlistStore: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/xVigil")
    }

    public let directory: URL

    public init(directory: URL = WatchlistStore.defaultDirectory) {
        self.directory = directory
    }

    public var entriesURL: URL { directory.appendingPathComponent("watchlist.json") }
    public var stateURL: URL { directory.appendingPathComponent("watchlist-state.json") }

    // MARK: - Entries

    /// Missing file means "no watchlist yet", not an error.
    public func loadEntries() throws -> [WatchlistEntry] {
        guard FileManager.default.fileExists(atPath: entriesURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: entriesURL)
            return try Self.decoder().decode(WatchlistFile.self, from: data).entries
        } catch {
            throw WatchlistStoreError.readFailed(entriesURL, error.localizedDescription)
        }
    }

    public func saveEntries(_ entries: [WatchlistEntry]) throws {
        try write(WatchlistFile(version: 1, entries: entries), to: entriesURL)
    }

    // MARK: - Check state

    private struct StateFile: Codable {
        var version: Int
        var state: [String: WatchlistCheckState]
    }

    /// Missing file means "never checked", not an error.
    public func loadState() throws -> [UUID: WatchlistCheckState] {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: stateURL)
            let file = try Self.decoder().decode(StateFile.self, from: data)
            var state: [UUID: WatchlistCheckState] = [:]
            for (key, value) in file.state {
                if let id = UUID(uuidString: key) { state[id] = value }
            }
            return state
        } catch {
            throw WatchlistStoreError.readFailed(stateURL, error.localizedDescription)
        }
    }

    /// Saves check state, pruning IDs absent from `entries` so state for
    /// deleted entries doesn't accumulate forever.
    public func saveState(
        _ state: [UUID: WatchlistCheckState], keeping entries: [WatchlistEntry]
    ) throws {
        let keep = Set(entries.map(\.id))
        let pruned = state.filter { keep.contains($0.key) }
        let file = StateFile(
            version: 1,
            state: Dictionary(
                uniqueKeysWithValues: pruned.map { ($0.key.uuidString, $0.value) }))
        try write(file, to: stateURL)
    }

    // MARK: - Merge

    /// Merges a fetched remote set into the current list: all `.local`
    /// entries are preserved, and the fetched set wholesale replaces any
    /// previous `.remote` entries. Dedup by id — on collision the local
    /// entry wins. Check state is untouched by merge (it lives in the
    /// separate state file keyed by ID), so a remote entry that persists
    /// across fetches keeps its integrity baselines by construction.
    public static func merge(
        remote: [WatchlistEntry], into local: [WatchlistEntry]
    ) -> [WatchlistEntry] {
        let kept = local.filter(\.source.isLocal)
        let keptIDs = Set(kept.map(\.id))
        var seen = Set<UUID>()
        let fetched = remote.filter { entry in
            guard !keptIDs.contains(entry.id), !seen.contains(entry.id) else { return false }
            seen.insert(entry.id)
            return true
        }
        return kept + fetched
    }

    // MARK: - JSON plumbing

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            throw WatchlistStoreError.writeFailed(url, error.localizedDescription)
        }
    }
}
