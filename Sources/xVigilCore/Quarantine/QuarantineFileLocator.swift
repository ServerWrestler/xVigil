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
    public var searchDirectories: [URL]
    /// Directory depth to descend below each search root.
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
        ]
    }

    public init(
        searchDirectories: [URL] = QuarantineFileLocator.defaultSearchDirectories,
        maxDepth: Int = 3,
        maxEntries: Int = 25_000
    ) {
        self.searchDirectories = searchDirectories
        self.maxDepth = maxDepth
        self.maxEntries = maxEntries
    }

    /// Scans the search directories for a file whose quarantine xattr matches
    /// `eventID`. Slow (filesystem walk) — call off the main thread.
    public func locate(eventID: String) -> URL? {
        let target = eventID.uppercased()
        var examined = 0

        for directory in searchDirectories {
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
                if examined > maxEntries { return nil }
                if Self.quarantineEventID(of: url)?.uppercased() == target {
                    return url
                }
            }
        }
        return nil
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
