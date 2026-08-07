import Foundation

/// Which check outcomes promote a finding to an app-wide alert (red menu
/// bar shield). Every check still records all facts; these only gate what
/// reaches `DetectionMonitor`.
public enum AlertCondition: String, Codable, Sendable, CaseIterable {
    /// Alert if a matching file EXISTS (IOC-style: listed because finding it is bad).
    case onPresence
    /// Alert if the target is MISSING (sentinel file). Literal targets only.
    case onAbsence
    /// Alert if a tracked hash CHANGED (integrity).
    case onChange
    /// Alert if a content regex MATCHED.
    case onMatch

    public var label: String {
        switch self {
        case .onPresence: "File is found"
        case .onAbsence: "File is missing"
        case .onChange: "File changed"
        case .onMatch: "Content matched"
        }
    }
}

/// One watchlist entry: a file target plus optional inspection layers.
/// Pure configuration — mutable check state (integrity baselines, findings)
/// lives in `WatchlistCheckState`, keyed by `id`, so remote refreshes never
/// clobber baselines and this type stays value-stable for list identity.
public struct WatchlistEntry: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    /// Absolute file path, directory, or glob. May start with "~" — the
    /// checker expands it before any filesystem access.
    public var target: String
    /// Human-friendly name.
    public var label: String
    public var notes: String?
    public var source: Source
    /// Deep enumeration for directory/glob targets.
    public var recursive: Bool
    /// SHA-256 hash + compare on each check.
    public var trackIntegrity: Bool
    /// Regex strings searched inside readable text files; empty = no content scan.
    public var contentPatterns: [String]
    /// See `AlertCondition`. When omitted from JSON, defaults are derived
    /// from the entry's shape via `defaultAlertConditions`.
    public var alertConditions: [AlertCondition]

    /// Where an entry came from. Local entries are user-owned and survive
    /// remote refreshes; remote entries are wholesale replaced on fetch.
    ///
    /// NOTE: must not declare a raw type — enums with associated values
    /// cannot have one. Codable is custom so the JSON stays hand-editable:
    /// `{ "type": "local" }` / `{ "type": "remote", "url": "…" }`.
    public enum Source: Codable, Sendable, Hashable {
        case local
        case remote(url: String)

        public var isLocal: Bool {
            if case .local = self { return true }
            return false
        }

        private enum CodingKeys: String, CodingKey {
            case type, url
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "local":
                self = .local
            case "remote":
                self = .remote(url: try container.decode(String.self, forKey: .url))
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container,
                    debugDescription: "unknown source type \"\(other)\"")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .local:
                try container.encode("local", forKey: .type)
            case .remote(let url):
                try container.encode("remote", forKey: .type)
                try container.encode(url, forKey: .url)
            }
        }
    }

    public init(
        id: UUID = UUID(),
        target: String,
        label: String,
        notes: String? = nil,
        source: Source = .local,
        recursive: Bool = false,
        trackIntegrity: Bool = false,
        contentPatterns: [String] = [],
        alertConditions: [AlertCondition]? = nil
    ) {
        self.id = id
        self.target = target
        self.label = label
        self.notes = notes
        self.source = source
        self.recursive = recursive
        self.trackIntegrity = trackIntegrity
        self.contentPatterns = contentPatterns
        self.alertConditions = alertConditions
            ?? Self.defaultAlertConditions(
                trackIntegrity: trackIntegrity, contentPatterns: contentPatterns)
    }

    /// The defaulting rule: a plain existence entry (no integrity, no
    /// patterns) alerts when the file IS FOUND — the IOC-hunting default.
    /// Integrity entries alert on change, pattern entries on match.
    /// `.onAbsence` is never a default; users opt in explicitly.
    public static func defaultAlertConditions(
        trackIntegrity: Bool, contentPatterns: [String]
    ) -> [AlertCondition] {
        var conditions: [AlertCondition] = []
        if trackIntegrity { conditions.append(.onChange) }
        if !contentPatterns.isEmpty { conditions.append(.onMatch) }
        if conditions.isEmpty { conditions = [.onPresence] }
        return conditions
    }

    // MARK: - Codable (tolerant of hand-edited and remote-feed JSON)

    private enum CodingKeys: String, CodingKey {
        case id, target, label, notes, source, recursive
        case trackIntegrity, contentPatterns, alertConditions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let target = try container.decode(String.self, forKey: .target)
        self.target = target
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.label = try container.decodeIfPresent(String.self, forKey: .label) ?? target
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
        self.source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .local
        self.recursive = try container.decodeIfPresent(Bool.self, forKey: .recursive) ?? false
        let trackIntegrity =
            try container.decodeIfPresent(Bool.self, forKey: .trackIntegrity) ?? false
        self.trackIntegrity = trackIntegrity
        let contentPatterns =
            try container.decodeIfPresent([String].self, forKey: .contentPatterns) ?? []
        self.contentPatterns = contentPatterns
        self.alertConditions =
            try container.decodeIfPresent([AlertCondition].self, forKey: .alertConditions)
            ?? Self.defaultAlertConditions(
                trackIntegrity: trackIntegrity, contentPatterns: contentPatterns)
    }
}
