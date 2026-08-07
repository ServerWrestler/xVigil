import Foundation

public enum WatchlistFetchError: Error, LocalizedError, Equatable {
    case insecureURL(String)
    case badResponse(Int)
    case malformed(String)
    case tooManyEntries(count: Int, limit: Int)
    case tooManyPatterns(entry: String, count: Int, limit: Int)
    case patternTooLong(entry: String, length: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .insecureURL(let url):
            "Refusing non-HTTPS watchlist URL: \(url)"
        case .badResponse(let code):
            "Watchlist fetch failed (HTTP \(code))"
        case .malformed(let detail):
            "Watchlist JSON is malformed: \(detail)"
        case .tooManyEntries(let count, let limit):
            "Feed has \(count) entries (limit \(limit))"
        case .tooManyPatterns(let entry, let count, let limit):
            "Entry \"\(entry)\" has \(count) patterns (limit \(limit))"
        case .patternTooLong(let entry, let length, let limit):
            "Entry \"\(entry)\" has a \(length)-character pattern (limit \(limit))"
        }
    }
}

/// Downloads a remote watchlist feed. The feed is untrusted input — this
/// is a security app, and a hostile or sloppy feed must not be able to
/// hang or mislead it. The fetcher enforces transport and size/shape
/// limits; regex validation happens in the checker (which also guards
/// local entries).
public struct WatchlistFetcher: Sendable {
    public static let maxEntries = 200
    public static let maxPatternsPerEntry = 32
    public static let maxPatternLength = 512
    public static let timeout: TimeInterval = 30

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches and validates a feed. Entries come back tagged
    /// `.remote(url:)` regardless of what the feed claims — the feed does
    /// not get to smuggle entries in as "local".
    public func fetch(from url: URL) async throws -> [WatchlistEntry] {
        guard url.scheme?.lowercased() == "https" else {
            throw WatchlistFetchError.insecureURL(url.absoluteString)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WatchlistFetchError.badResponse(http.statusCode)
        }

        let file: WatchlistFile
        do {
            file = try WatchlistStore.decoder().decode(WatchlistFile.self, from: data)
        } catch {
            throw WatchlistFetchError.malformed(error.localizedDescription)
        }

        try Self.validate(file.entries)
        return file.entries.map { entry in
            var tagged = entry
            tagged.source = .remote(url: url.absoluteString)
            return tagged
        }
    }

    /// Size/shape caps, enforced before anything touches the filesystem.
    static func validate(_ entries: [WatchlistEntry]) throws {
        guard entries.count <= maxEntries else {
            throw WatchlistFetchError.tooManyEntries(
                count: entries.count, limit: maxEntries)
        }
        for entry in entries {
            guard entry.contentPatterns.count <= maxPatternsPerEntry else {
                throw WatchlistFetchError.tooManyPatterns(
                    entry: entry.label, count: entry.contentPatterns.count,
                    limit: maxPatternsPerEntry)
            }
            for pattern in entry.contentPatterns where pattern.count > maxPatternLength {
                throw WatchlistFetchError.patternTooLong(
                    entry: entry.label, length: pattern.count, limit: maxPatternLength)
            }
        }
    }
}
