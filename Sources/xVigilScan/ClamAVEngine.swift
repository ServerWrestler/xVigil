import Foundation
import xVigilCore

/// ClamAV backend. Detects a user-installed ClamAV (typically via Homebrew)
/// rather than bundling one — keeps licensing clean and the "user-defined
/// engine" framing honest. Prefers `clamdscan` (daemon; no ~200MB signature
/// reload per run) and falls back to `clamscan`.
public struct ClamAVEngine: ScanEngine {
    public let id = "clamav"
    public let displayName = "ClamAV"

    /// Homebrew prefixes to probe. GUI apps get a minimal PATH from launchd,
    /// so we check known locations instead of relying on `which`.
    static let prefixes = ["/opt/homebrew", "/usr/local"]

    private let clamdscanOverride: URL?
    private let clamscanOverride: URL?
    private let databaseDirectoryOverride: URL?

    public init(
        clamdscan: URL? = nil,
        clamscan: URL? = nil,
        databaseDirectory: URL? = nil
    ) {
        self.clamdscanOverride = clamdscan
        self.clamscanOverride = clamscan
        self.databaseDirectoryOverride = databaseDirectory
    }

    // MARK: - Availability

    public func availability() async -> EngineAvailability {
        let engine = self
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: engine.checkAvailability())
            }
        }
    }

    func checkAvailability() -> EngineAvailability {
        let clamdscan = clamdscanOverride?.path ?? Self.findExecutable("clamdscan")
        let clamscan = clamscanOverride?.path ?? Self.findExecutable("clamscan")

        guard clamdscan != nil || clamscan != nil else {
            return EngineAvailability(
                installed: false, daemonRunning: false, scannerPath: nil,
                signatureAge: nil,
                detail: "ClamAV not found. Install with: brew install clamav")
        }

        // `clamdscan --ping 1` waits up to 1s for the daemon.
        var daemonRunning = false
        if let clamdscan {
            let ping = try? Subprocess.run(
                clamdscan, arguments: ["--ping", "1"], timeout: 10)
            daemonRunning = ping?.status == 0
        }

        let scanner = daemonRunning ? clamdscan : clamscan
        let signatureAge = signatureDatabaseAge(scannerPath: scanner ?? clamdscan)

        var parts: [String] = []
        if let scanner { parts.append(scanner) }
        parts.append(daemonRunning
            ? "daemon running (fast scans)"
            : "daemon not running — falling back to clamscan, which reloads "
                + "the full signature database each run (slow start)")
        return EngineAvailability(
            installed: true,
            daemonRunning: daemonRunning,
            scannerPath: scanner,
            signatureAge: signatureAge,
            detail: parts.joined(separator: "\n"))
    }

    static func findExecutable(_ name: String) -> String? {
        for prefix in prefixes {
            let candidate = "\(prefix)/bin/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Newest signature file (*.cvd/*.cld) in the database directory.
    /// Homebrew keeps it at <prefix>/var/lib/clamav.
    func signatureDatabaseAge(scannerPath: String?) -> TimeInterval? {
        let directory: URL
        if let databaseDirectoryOverride {
            directory = databaseDirectoryOverride
        } else if let scannerPath {
            directory = URL(fileURLWithPath: scannerPath)
                .deletingLastPathComponent()   // bin
                .deletingLastPathComponent()   // prefix
                .appendingPathComponent("var/lib/clamav")
        } else {
            return nil
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }

        let newest = entries
            .filter { ["cvd", "cld"].contains($0.pathExtension.lowercased()) }
            .compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            }
            .max()
        return newest.map { Date().timeIntervalSince($0) }
    }

    // MARK: - Scanning

    public func scan(paths: [URL], options: ScanOptions = ScanOptions()) -> AsyncStream<ScanEvent> {
        let engine = self
        return AsyncStream { continuation in
            let task = Task {
                await engine.runScan(paths: paths, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runScan(
        paths: [URL],
        continuation: AsyncStream<ScanEvent>.Continuation
    ) async {
        let availability = await availability()
        guard let scanner = availability.scannerPath else {
            continuation.yield(.finished(ScanSummary(
                infectedCount: 0, scannedCount: nil, duration: 0,
                exitStatus: -1, errorMessage: availability.detail)))
            return
        }

        // --fdpass hands clamd our file descriptors so the daemon can scan
        // paths its own user can't read. --infected keeps output to hits only.
        var arguments = availability.daemonRunning
            ? ["--fdpass", "--infected", "--multiscan", "--stdout"]
            : ["--infected", "--recursive", "--stdout"]
        arguments += paths.map(\.path)

        continuation.yield(.started(scanner: scanner, paths: paths.map(\.path)))
        let start = Date()
        var infected = 0
        var scanned: Int?
        var lastErrorLine: String?

        do {
            for await event in try Subprocess.streamLines(scanner, arguments: arguments) {
                switch event {
                case .line(let line):
                    switch Self.parseLine(line) {
                    case .threat(let path, let signature):
                        infected += 1
                        continuation.yield(.threatFound(path: path, signature: signature))
                    case .scannedCount(let count):
                        scanned = count
                    case .noise:
                        break
                    case .other(let message):
                        lastErrorLine = message
                        continuation.yield(.progress(message: message))
                    }
                case .exited(let status):
                    // clamscan exit codes: 0 clean, 1 threats found, 2 error.
                    continuation.yield(.finished(ScanSummary(
                        infectedCount: infected,
                        scannedCount: scanned,
                        duration: Date().timeIntervalSince(start),
                        exitStatus: status,
                        errorMessage: status > 1 ? (lastErrorLine ?? "scan failed") : nil)))
                }
            }
        } catch {
            continuation.yield(.finished(ScanSummary(
                infectedCount: infected, scannedCount: scanned,
                duration: Date().timeIntervalSince(start),
                exitStatus: -1, errorMessage: error.localizedDescription)))
        }
    }

    // MARK: - Output parsing

    enum ParsedLine: Equatable {
        case threat(path: String, signature: String)
        case scannedCount(Int)
        case noise
        case other(String)
    }

    /// clamscan/clamdscan output: one `path: Signature FOUND` line per hit,
    /// then a summary block.
    static func parseLine(_ line: String) -> ParsedLine {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .noise }

        if trimmed.hasSuffix(" FOUND") {
            let body = trimmed.dropLast(" FOUND".count)
            if let separator = body.range(of: ": ", options: .backwards) {
                return .threat(
                    path: String(body[..<separator.lowerBound]),
                    signature: String(body[separator.upperBound...]))
            }
            return .other(trimmed)
        }

        if trimmed.hasPrefix("Scanned files:"),
            let count = Int(trimmed.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces) ?? "") {
            return .scannedCount(count)
        }

        // Summary block and per-file OK lines are noise; anything else
        // (warnings, permission errors) is worth surfacing.
        let noisePrefixes = [
            "-----------", "Infected files:", "Known viruses:", "Engine version:",
            "Data scanned:", "Data read:", "Time:", "Start Date:", "End Date:",
            "Total errors:", "Scanned directories:",
        ]
        if noisePrefixes.contains(where: trimmed.hasPrefix) || trimmed.hasSuffix(": OK") {
            return .noise
        }
        return .other(trimmed)
    }
}
