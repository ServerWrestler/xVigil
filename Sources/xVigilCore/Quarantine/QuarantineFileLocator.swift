import Darwin
import Foundation

/// Finds the on-disk file for a quarantine event.
///
/// The quarantine database stores no file path. The linkage goes the other
/// way: quarantined files carry a `com.apple.quarantine` extended attribute
/// of the form `flags;hex-timestamp;agent;event-UUID`, where the fourth field
/// keys back into the database. So locating a file means scanning likely
/// directories for a matching UUID.
public struct QuarantineFileLocator: Sendable {
    /// What a search found — and, as importantly, what it couldn't look at.
    /// Most quarantine events on a typical Mac are message attachments whose
    /// files live in TCC-protected locations; "not found" is misleading
    /// unless the caller can say the search was incomplete.
    public struct Outcome: Equatable, Sendable {
        public let url: URL?
        /// Directories that exist but could not be read (typically missing
        /// Full Disk Access).
        public let unreadable: [String]
        /// True when the entry budget ran out before the search finished.
        public let truncated: Bool
    }

    public var searchDirectories: [URL]
    /// Directory depth to descend below each search root. Messages nests
    /// attachments four levels deep (Attachments/xx/yy/UUID/file).
    public var maxDepth: Int
    /// Upper bound on filesystem entries examined, as a runaway guard.
    public var maxEntries: Int

    public static var defaultSearchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications"),
            // Where message and mail attachments actually land — the majority
            // of quarantine events. TCC-protected: readable only with Full
            // Disk Access, reported via Outcome.unreadable otherwise.
            home.appendingPathComponent("Library/Messages/Attachments"),
            home.appendingPathComponent(
                "Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
            home.appendingPathComponent("Library/Mail Downloads"),
        ]
    }

    public init(
        searchDirectories: [URL] = QuarantineFileLocator.defaultSearchDirectories,
        maxDepth: Int = 5,
        maxEntries: Int = 50_000
    ) {
        self.searchDirectories = searchDirectories
        self.maxDepth = maxDepth
        self.maxEntries = maxEntries
    }

    /// Scans the search directories for a file whose quarantine xattr matches
    /// `eventID`. Slow (filesystem walk) — call off the main thread.
    public func search(eventID: String) -> Outcome {
        let target = eventID.uppercased()
        var examined = 0
        var unreadable: [String] = []

        for directory in searchDirectories {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: directory.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }

            // TCC-blocked directories make enumerators silently yield
            // nothing; probe explicitly so the caller can report why the
            // search was incomplete.
            guard (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) != nil
            else {
                unreadable.append(directory.path)
                continue
            }

            // .skipsPackageDescendants: .app bundles carry the xattr on the
            // bundle directory itself, so there is no need to look inside.
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                if enumerator.level > maxDepth {
                    enumerator.skipDescendants()
                    continue
                }
                examined += 1
                if examined > maxEntries {
                    return Outcome(url: nil, unreadable: unreadable, truncated: true)
                }
                if Self.quarantineEventID(of: url)?.uppercased() == target {
                    return Outcome(url: url, unreadable: unreadable, truncated: false)
                }
            }
        }
        return Outcome(url: nil, unreadable: unreadable, truncated: false)
    }

    /// Convenience for callers that only need the location.
    public func locate(eventID: String) -> URL? {
        search(eventID: eventID).url
    }

    /// Reads the event UUID out of a file's `com.apple.quarantine` xattr,
    /// or nil if the file has no quarantine xattr or it carries no UUID.
    public static func quarantineEventID(of url: URL) -> String? {
        guard let raw = extendedAttribute("com.apple.quarantine", of: url.path) else {
            return nil
        }
        let fields = raw.components(separatedBy: ";")
        guard fields.count >= 4, !fields[3].isEmpty else { return nil }
        return fields[3]
    }

    private static func extendedAttribute(_ name: String, of path: String) -> String? {
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = getxattr(path, name, &buffer, length, 0, 0)
        guard read == length else { return nil }
        return String(bytes: buffer, encoding: .utf8)
    }
}
