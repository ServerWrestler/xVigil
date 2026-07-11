import Foundation

public enum XProtectLogReaderError: Error, LocalizedError {
    case logCommandFailed(status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .logCommandFailed(let status, let stderr):
            "log show exited with status \(status): \(stderr)"
        }
    }
}

/// Reads XProtect / Gatekeeper activity from the unified log by shelling out
/// to `/usr/bin/log show`.
///
/// Note: the full path matters — zsh has a `log` builtin that shadows the
/// system binary.
public struct XProtectLogReader: Sendable {
    /// Matches XProtect services (XProtectService, XProtectBridgeService,
    /// XProtectRemediator*) plus Gatekeeper assessments from syspolicyd.
    public static let defaultPredicate = """
        subsystem BEGINSWITH "com.apple.XProtect" \
        OR process BEGINSWITH "XProtect" \
        OR (process == "syspolicyd" AND eventMessage CONTAINS[c] "assessment")
        """

    public let predicate: String

    public init(predicate: String = XProtectLogReader.defaultPredicate) {
        self.predicate = predicate
    }

    /// Fetches entries from the last `window` (a `log show --last` value such
    /// as "30m", "2h", or "1d"), newest last. Archive scans are slow — expect
    /// tens of seconds for long windows; the timeout converts a runaway query
    /// into an error instead of an eternal spinner.
    public func entries(
        last window: String = "1h",
        timeout: TimeInterval = 240
    ) async throws -> [XProtectLogEntry] {
        try await runAndParse(
            [
                "show",
                "--last", window,
                "--style", "ndjson",
                "--predicate", predicate,
            ],
            timeout: timeout)
    }

    /// Fetches entries in an absolute time range — used to pull log context
    /// around a quarantine event. Returns an empty array when the unified log
    /// archive no longer reaches back that far.
    public func entries(
        from start: Date,
        to end: Date,
        timeout: TimeInterval = 120
    ) async throws -> [XProtectLogEntry] {
        try await runAndParse(
            [
                "show",
                "--start", Self.logDateFormatter.string(from: start),
                "--end", Self.logDateFormatter.string(from: end),
                "--style", "ndjson",
                "--predicate", predicate,
            ],
            timeout: timeout)
    }

    /// `log show` accepts "YYYY-MM-DD HH:MM:SS" in local time.
    private static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func runAndParse(
        _ arguments: [String],
        timeout: TimeInterval
    ) async throws -> [XProtectLogEntry] {
        // Full path matters: zsh has a `log` builtin, and we never want to
        // depend on PATH resolution anyway.
        let result = try await Subprocess.runAsync(
            "/usr/bin/log", arguments: arguments, timeout: timeout)
        guard result.status == 0 else {
            throw XProtectLogReaderError.logCommandFailed(
                status: result.status, stderr: result.stderrText)
        }
        return XProtectLogParser.parse(ndjson: result.stdoutText)
    }
}
