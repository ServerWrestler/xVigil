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
    /// Caveats about the search itself: locations that couldn't be read
    /// (Full Disk Access) or a truncated walk. Empty means the search was
    /// complete — "not found" can be trusted.
    public let searchNotes: [String]
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

/// Delivers the first of two racing producers (blocking work vs. a timeout)
/// to a continuation exactly once; later arrivals are dropped.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var timer: DispatchSourceTimer?

    func attach(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }
    func retainTimer(_ timer: DispatchSourceTimer) {
        lock.lock(); self.timer = timer; lock.unlock()
    }
    func resume(_ value: T) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}

/// Enriches a quarantine event with on-disk evidence: locates the file via
/// its quarantine xattr, then asks Gatekeeper and codesign for a verdict.
public struct EventEnricher: Sendable {
    private let locator: QuarantineFileLocator

    public init(locator: QuarantineFileLocator = QuarantineFileLocator()) {
        self.locator = locator
    }

    /// Hard wall-clock ceiling on the whole enrichment. The in-walk
    /// cooperative deadline can't interrupt a blocked syscall (a stalled
    /// mount, or an iCloud file mid-materialization), so a wedged walk would
    /// otherwise spin the "On disk" field forever. This races the blocking
    /// work against a timer and returns a definite answer either way.
    public static let hardTimeout: TimeInterval = 15

    /// Dedicated queue so a wedged walk can't consume shared global-pool
    /// threads that other work (log queries) needs.
    private static let walkQueue = DispatchQueue(
        label: "io.xvigil.enrich", qos: .userInitiated, attributes: .concurrent)

    /// Slow (filesystem walk plus subprocess calls). Runs off the cooperative
    /// pool on a dedicated queue, and always returns within `hardTimeout`.
    public func enrich(_ event: QuarantineEvent) async -> EventEnrichment {
        let locator = self.locator
        return await Self.withHardTimeout(
            seconds: Self.hardTimeout,
            work: { Self.enrichBlocking(event, locator: locator) },
            onTimeout: { Self.timedOutEnrichment(after: Self.hardTimeout) })
    }

    static func timedOutEnrichment(after seconds: TimeInterval) -> EventEnrichment {
        EventEnrichment(
            fileStatus: .notFound,
            searchNotes: ["Search timed out after \(Int(seconds))s — a file "
                + "(often an iCloud or network item) was slow to read. "
                + "The file may still exist locally."],
            assessment: nil, signature: nil)
    }

    /// Runs blocking `work` on the dedicated walk queue and returns its result,
    /// or `onTimeout()` if `work` hasn't finished within `seconds`. A wedged
    /// `work` (blocked syscall) is abandoned: it keeps running and leaks its
    /// thread, but the caller resumes at the timeout regardless — the UI is
    /// never held hostage to a stuck read. A structured task group can't do
    /// this (it awaits all children at scope exit, so a wedged child blocks
    /// the return); this races a single continuation instead. Generic so the
    /// behavior is unit-testable without a real filesystem wedge.
    static func withHardTimeout<T: Sendable>(
        seconds: TimeInterval,
        work: @escaping @Sendable () -> T,
        onTimeout: @escaping @Sendable () -> T
    ) async -> T {
        let gate = ResumeOnce<T>()
        return await withCheckedContinuation { continuation in
            gate.attach(continuation)
            walkQueue.async { gate.resume(work()) }
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + seconds)
            timer.setEventHandler { gate.resume(onTimeout()) }
            timer.activate()
            gate.retainTimer(timer)
        }
    }

    static func enrichBlocking(
        _ event: QuarantineEvent,
        locator: QuarantineFileLocator
    ) -> EventEnrichment {
        var prioritized = locator
        prioritized.searchDirectories = Self.prioritizedDirectories(
            locator.searchDirectories, for: event.kind)

        let outcome = prioritized.search(eventID: event.id)
        let notes = searchNotes(for: outcome, locator: prioritized)

        guard let url = outcome.url else {
            return EventEnrichment(
                fileStatus: .notFound, searchNotes: notes, assessment: nil, signature: nil)
        }
        return EventEnrichment(
            fileStatus: .found(path: url.path),
            searchNotes: notes,
            assessment: assess(url),
            signature: signature(of: url)
        )
    }

    /// Search where this kind of event's file most likely lives first —
    /// message attachments sit under ~/Library/Messages, not Downloads.
    static func prioritizedDirectories(
        _ directories: [URL],
        for kind: QuarantineEvent.Kind
    ) -> [URL] {
        let marker: String?
        switch kind {
        case .messageAttachment: marker = "Library/Messages"
        case .emailAttachment: marker = "Mail"
        default: marker = nil
        }
        guard let marker else { return directories }
        let preferred = directories.filter { $0.path.contains(marker) }
        return preferred + directories.filter { !$0.path.contains(marker) }
    }

    private static func searchNotes(
        for outcome: QuarantineFileLocator.Outcome,
        locator: QuarantineFileLocator
    ) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var notes = outcome.unreadable.map { path in
            let display = path.hasPrefix(home)
                ? "~" + path.dropFirst(home.count) : path
            return "\(display) couldn't be searched — grant xVigil Full Disk Access "
                + "(System Settings → Privacy & Security) to include it."
        }
        if outcome.truncated {
            notes.append(
                "Search stopped early (budget: \(locator.maxEntries) files / "
                + "\(Int(locator.maxSeconds))s) — the file may exist in an unsearched spot.")
        }
        return notes
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
