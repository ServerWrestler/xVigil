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
    /// as "30m", "2h", or "1d"), newest last.
    public func entries(last window: String = "1h") throws -> [XProtectLogEntry] {
        let output = try runLog(arguments: [
            "show",
            "--last", window,
            "--style", "ndjson",
            "--predicate", predicate,
        ])
        return XProtectLogParser.parse(ndjson: output)
    }

    private func runLog(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        // Read before waiting so a large result can't deadlock on a full pipe.
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw XProtectLogReaderError.logCommandFailed(
                status: process.terminationStatus,
                stderr: String(data: errorData, encoding: .utf8) ?? ""
            )
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
