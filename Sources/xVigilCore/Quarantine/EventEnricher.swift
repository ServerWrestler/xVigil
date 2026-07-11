import Foundation

/// Everything we could learn about a quarantine event beyond the database row.
public struct EventEnrichment: Equatable, Sendable {
    public enum FileStatus: Equatable, Sendable {
        /// File located on disk via its quarantine xattr.
        case found(path: String)
        /// Not found in the search directories — most often deleted, which is
        /// a normal state for historical events, not an error.
        case notFound
    }

    public let fileStatus: FileStatus
    /// Gatekeeper's verdict on the file today. Nil when the file wasn't found
    /// or isn't an assessable type (app/pkg/dmg).
    public let assessment: GatekeeperAssessment?
    /// Code signature details. Nil when the file wasn't found.
    public let signature: CodeSignature?
}

public struct GatekeeperAssessment: Equatable, Sendable {
    public let accepted: Bool
    /// spctl's own explanation, e.g. "source=Notarized Developer ID".
    public let detail: String
}

public struct CodeSignature: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case signed
        case unsigned
        case invalid
    }

    public let status: Status
    /// Certificate chain, leaf first (codesign "Authority" lines).
    public let authorities: [String]
    /// First diagnostic line when the signature is invalid.
    public let problem: String?
}

/// Enriches a quarantine event with on-disk evidence: locates the file via
/// its quarantine xattr, then asks Gatekeeper and codesign for a verdict.
public struct EventEnricher: Sendable {
    private let locator: QuarantineFileLocator

    public init(locator: QuarantineFileLocator = QuarantineFileLocator()) {
        self.locator = locator
    }

    /// Slow (filesystem walk plus subprocess calls). The blocking work runs
    /// on a GCD thread so it never occupies the cooperative pool.
    public func enrich(_ event: QuarantineEvent) async -> EventEnrichment {
        let locator = self.locator
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.enrichBlocking(event, locator: locator))
            }
        }
    }

    static func enrichBlocking(
        _ event: QuarantineEvent,
        locator: QuarantineFileLocator
    ) -> EventEnrichment {
        guard let url = locator.locate(eventID: event.id) else {
            return EventEnrichment(fileStatus: .notFound, assessment: nil, signature: nil)
        }
        return EventEnrichment(
            fileStatus: .found(path: url.path),
            assessment: assess(url),
            signature: signature(of: url)
        )
    }

    // MARK: - Gatekeeper (spctl)

    private static func assess(_ url: URL) -> GatekeeperAssessment? {
        let arguments: [String]
        switch url.pathExtension.lowercased() {
        case "app":
            arguments = ["--assess", "--type", "execute", "-vv", url.path]
        case "pkg", "mpkg":
            arguments = ["--assess", "--type", "install", "-vv", url.path]
        case "dmg":
            arguments = [
                "--assess", "--type", "open",
                "--context", "context:primary-signature", "-vv", url.path,
            ]
        default:
            return nil  // Gatekeeper assessment only applies to app/pkg/dmg.
        }

        guard let result = try? Subprocess.run(
            "/usr/sbin/spctl", arguments: arguments, timeout: 30)
        else { return nil }
        return GatekeeperAssessment(
            accepted: result.status == 0,
            detail: Self.parseSpctlDetail(result.combinedText)
        )
    }

    /// Pulls the explanatory lines (source=, origin=, or the verdict line)
    /// out of spctl's output.
    static func parseSpctlDetail(_ output: String) -> String {
        let lines = output.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let detail = lines.filter {
            $0.hasPrefix("source=") || $0.hasPrefix("origin=")
        }
        if !detail.isEmpty { return detail.joined(separator: "\n") }
        return lines.first ?? ""
    }

    // MARK: - Code signature (codesign)

    private static func signature(of url: URL) -> CodeSignature {
        guard let result = try? Subprocess.run(
            "/usr/bin/codesign", arguments: ["-dv", "--verbose=2", url.path], timeout: 15)
        else {
            return CodeSignature(status: .invalid, authorities: [], problem: "codesign failed to run")
        }
        // codesign writes its report to stderr.
        return Self.parseCodesign(status: result.status, output: result.stderrText)
    }

    static func parseCodesign(status: Int32, output: String) -> CodeSignature {
        guard status == 0 else {
            if output.contains("not signed at all") {
                return CodeSignature(status: .unsigned, authorities: [], problem: nil)
            }
            let problem = output.split(separator: "\n").first.map(String.init)
            return CodeSignature(status: .invalid, authorities: [], problem: problem)
        }
        let authorities = output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Authority=") }
            .map { String($0.dropFirst("Authority=".count)) }
        return CodeSignature(status: .signed, authorities: authorities, problem: nil)
    }
}
