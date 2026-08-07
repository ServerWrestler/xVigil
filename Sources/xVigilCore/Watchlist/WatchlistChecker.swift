import CryptoKit
import Foundation

/// Streamed progress of a watchlist check pass.
public enum WatchlistEvent: Sendable {
    case checking(entry: WatchlistEntry)
    case found(WatchlistFinding, for: WatchlistEntry)
    /// Entry finished; carries its fully updated check state (new
    /// baselines, findings, lastChecked). The caller persists it.
    case completed(entry: WatchlistEntry, state: WatchlistCheckState)
    case failed(entry: WatchlistEntry, error: String)
    case finished
}

/// The check engine: resolves targets (tilde, literal, glob, recursive),
/// checks existence, hashes for integrity, and regex-scans text content.
/// Pure data work — no UI dependency; report-only by contract (never
/// modifies, quarantines, or deletes anything it finds).
public struct WatchlistChecker: Sendable {
    /// Max resolved files per entry; beyond this the entry's findings gain
    /// a "truncated" error and resolution stops.
    public static let maxResolvedFiles = 500
    /// Files larger than this are skipped for content scanning.
    public static let maxContentScanBytes = 1_048_576
    /// Wall-clock budget for regex matching per file — a hostile feed
    /// pattern (catastrophic backtracking) must not hang the pass.
    public static let contentScanBudget: TimeInterval = 2

    public init() {}

    /// Streams check events as they complete. One pass over all entries.
    /// `state` supplies prior baselines; consume `.completed` events to
    /// collect the updated state and persist it.
    public func check(
        entries: [WatchlistEntry],
        state: [UUID: WatchlistCheckState]
    ) -> AsyncStream<WatchlistEvent> {
        AsyncStream { continuation in
            // Detached: this is blocking filesystem work (walks, hashing,
            // regex) that must stay off the cooperative pool.
            let task = Task.detached(priority: .utility) {
                for entry in entries {
                    if Task.isCancelled { break }
                    continuation.yield(.checking(entry: entry))
                    let prior = state[entry.id] ?? WatchlistCheckState()
                    let updated = Self.checkEntry(entry, prior: prior) { finding in
                        continuation.yield(.found(finding, for: entry))
                    }
                    continuation.yield(.completed(entry: entry, state: updated))
                }
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Per-entry check

    static func checkEntry(
        _ entry: WatchlistEntry,
        prior: WatchlistCheckState,
        onFinding: (WatchlistFinding) -> Void
    ) -> WatchlistCheckState {
        var findings: [WatchlistFinding] = []
        var baselines: [String: String] = [:]
        func record(_ finding: WatchlistFinding) {
            findings.append(finding)
            onFinding(finding)
        }

        // 1. Tilde expansion — FileManager does NOT expand "~"; without
        // this an entry like "~/Library/…" silently matches nothing.
        let target = (entry.target as NSString).expandingTildeInPath

        // 2. Validate regexes up front. Invalid patterns are recorded and
        // skipped; they never abort the entry or the pass.
        var regexes: [(pattern: String, regex: NSRegularExpression)] = []
        for pattern in entry.contentPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                regexes.append((pattern, regex))
            } else {
                record(WatchlistFinding(
                    path: target, exists: false,
                    error: "invalid pattern skipped: \(pattern)"))
            }
        }

        // 3. Resolve the target to concrete file paths.
        let resolution = resolve(target: target, recursive: entry.recursive)

        if resolution.paths.isEmpty && !resolution.truncated {
            // Absent literal target (globs that match nothing stay silent —
            // "no IOC files present" is the good outcome, not a finding).
            if !containsGlobCharacters(target) {
                record(WatchlistFinding(
                    path: target, exists: false,
                    isAlert: entry.alertConditions.contains(.onAbsence)))
            }
        }

        // 4/5. Check each resolved file.
        for path in resolution.paths {
            var hashChanged: Bool?
            if entry.trackIntegrity {
                if let hash = sha256OfFile(atPath: path) {
                    // First sighting is a baseline, not a change.
                    hashChanged = prior.baselineHashes[path].map { $0 != hash }
                    baselines[path] = hash
                }
            }

            var matched: [String] = []
            var scanError: String?
            if !regexes.isEmpty {
                (matched, scanError) = scanContent(atPath: path, regexes: regexes)
            }

            let isAlert =
                (entry.alertConditions.contains(.onPresence))
                || (entry.alertConditions.contains(.onChange) && hashChanged == true)
                || (entry.alertConditions.contains(.onMatch) && !matched.isEmpty)

            record(WatchlistFinding(
                path: path, exists: true, hashChanged: hashChanged,
                matchedPatterns: matched, error: scanError, isAlert: isAlert))
        }

        if resolution.truncated {
            record(WatchlistFinding(
                path: target, exists: true,
                error: "truncated at \(maxResolvedFiles) files — refine pattern"))
        }

        return WatchlistCheckState(
            lastChecked: Date(), baselineHashes: baselines, findings: findings)
    }

    // MARK: - Target resolution

    static func containsGlobCharacters(_ path: String) -> Bool {
        path.contains("*") || path.contains("?") || path.contains("[")
    }

    /// Splits a glob path into its literal directory prefix and the glob
    /// remainder: "/a/b/*.plist" → ("/a/b", "*.plist").
    static func splitGlob(_ path: String) -> (base: String, pattern: String) {
        let components = (path as NSString).pathComponents
        var base: [String] = []
        var index = 0
        while index < components.count, !containsGlobCharacters(components[index]) {
            base.append(components[index])
            index += 1
        }
        return (
            NSString.path(withComponents: base),
            components[index...].joined(separator: "/")
        )
    }

    struct Resolution {
        var paths: [String] = []
        var truncated = false
    }

    /// Resolves a (tilde-expanded) target to regular files, capped at
    /// `maxResolvedFiles`.
    static func resolve(target: String, recursive: Bool) -> Resolution {
        let fm = FileManager.default
        var resolution = Resolution()

        if containsGlobCharacters(target) {
            let (base, pattern) = splitGlob(target)
            for relative in enumerateRelativePaths(in: base, deep: recursive) {
                // fnmatch without FNM_PATHNAME: "*" crosses "/" so patterns
                // like "*.plist" also match nested files on recursive walks.
                if fnmatch(pattern, relative, 0) == 0 {
                    resolution.paths.append((base as NSString).appendingPathComponent(relative))
                    if resolution.paths.count >= maxResolvedFiles {
                        resolution.truncated = true
                        break
                    }
                }
            }
            return resolution
        }

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target, isDirectory: &isDirectory) else {
            return resolution
        }
        guard isDirectory.boolValue else {
            resolution.paths = [target]
            return resolution
        }
        for relative in enumerateRelativePaths(in: target, deep: recursive) {
            resolution.paths.append((target as NSString).appendingPathComponent(relative))
            if resolution.paths.count >= maxResolvedFiles {
                resolution.truncated = true
                break
            }
        }
        return resolution
    }

    /// Relative paths of regular files under `directory` — one level when
    /// `deep` is false, the full tree when true. Sorted for determinism.
    private static func enumerateRelativePaths(in directory: String, deep: Bool) -> [String] {
        let fm = FileManager.default
        let directoryURL = URL(fileURLWithPath: directory)
        var relative: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]

        if deep {
            guard let enumerator = fm.enumerator(
                at: directoryURL, includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants])
            else { return [] }
            let prefix = directoryURL.standardizedFileURL.path
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile == true else { continue }
                let full = url.standardizedFileURL.path
                if full.hasPrefix(prefix + "/") {
                    relative.append(String(full.dropFirst(prefix.count + 1)))
                }
            }
        } else {
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
            for name in names {
                var isDirectory: ObjCBool = false
                let full = (directory as NSString).appendingPathComponent(name)
                if fm.fileExists(atPath: full, isDirectory: &isDirectory),
                    !isDirectory.boolValue {
                    relative.append(name)
                }
            }
        }
        return relative.sorted()
    }

    // MARK: - Integrity hashing

    /// Streaming SHA-256 so large files never load fully into memory.
    static func sha256OfFile(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Content scanning

    /// Regex-scans a file's contents. Skips oversized files, sniffs out
    /// binaries (NUL byte / non-UTF-8 in the first 8 KB), and enforces a
    /// wall-clock budget between patterns as a ReDoS guard.
    static func scanContent(
        atPath path: String,
        regexes: [(pattern: String, regex: NSRegularExpression)]
    ) -> (matched: [String], error: String?) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: path),
            let size = attributes[.size] as? Int
        else { return ([], "unreadable — skipped content scan") }
        guard size <= maxContentScanBytes else {
            return ([], "file too large, skipped content scan")
        }
        guard let data = fm.contents(atPath: path) else {
            return ([], "unreadable — skipped content scan")
        }

        // Binary sniff: regex-scanning Mach-O bytes as text is noise.
        if data.prefix(8192).contains(0) { return ([], nil) }
        guard let text = String(data: data, encoding: .utf8) else { return ([], nil) }

        var matched: [String] = []
        let deadline = Date().addingTimeInterval(contentScanBudget)
        let range = NSRange(text.startIndex..., in: text)
        for (pattern, regex) in regexes {
            if Date() > deadline { return (matched, "content scan timed out") }
            if regex.firstMatch(in: text, range: range) != nil {
                matched.append(pattern)
            }
        }
        return (matched, nil)
    }
}
