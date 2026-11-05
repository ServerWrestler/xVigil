import Foundation
import xVigilCore

/// One-click upkeep for a Homebrew-installed ClamAV: `brew update`, then
/// `brew upgrade clamav`, then `freshclam`. Deliberately scoped to ClamAV:
/// a bare `brew upgrade` would upgrade every outdated package on the machine,
/// which is not xVigil's business.
///
/// xVigil never installs Homebrew or ClamAV. When either is missing,
/// `readiness()` says so and the UI shows a text suggestion instead of a
/// button.
public struct ClamAVMaintenance: Sendable {
    public enum Readiness: Equatable, Sendable {
        /// Homebrew and ClamAV are both installed and freshclam is configured.
        case ready
        /// At least one of Homebrew / ClamAV is not installed. Each flag is
        /// true when that component is the one that's missing.
        case missing(homebrewMissing: Bool, clamavMissing: Bool)
        /// Both installed, but Homebrew ships only `freshclam.conf.sample`
        /// and freshclam refuses to run without a real config. Carries the
        /// config path that needs to exist.
        case needsConfig(String)
    }

    public struct Step: Equatable, Sendable {
        public let title: String
        let executable: String
        let arguments: [String]
    }

    public enum Event: Sendable {
        case stepStarted(index: Int, title: String)
        case output(String)
        case stepFinished(index: Int, succeeded: Bool)
        case finished(Result)
    }

    public struct Result: Equatable, Sendable {
        public let succeeded: Bool
        public let message: String
        public let duration: TimeInterval

        public init(succeeded: Bool, message: String, duration: TimeInterval) {
            self.succeeded = succeeded
            self.message = message
            self.duration = duration
        }
    }

    /// Homebrew prefixes to probe: Apple Silicon first, then Intel.
    private let prefixes: [String]

    public init(prefixes: [String] = ["/opt/homebrew", "/usr/local"]) {
        self.prefixes = prefixes
    }

    // MARK: - Readiness

    public func readiness() -> Readiness {
        let fm = FileManager.default
        func has(_ prefix: String, _ tool: String) -> Bool {
            fm.isExecutableFile(atPath: "\(prefix)/bin/\(tool)")
        }

        guard let prefix = prefixes.first(where: { has($0, "brew") }) else {
            let clamavInstalled = prefixes.contains { has($0, "freshclam") }
            return .missing(homebrewMissing: true, clamavMissing: !clamavInstalled)
        }
        guard has(prefix, "freshclam") else {
            return .missing(homebrewMissing: false, clamavMissing: true)
        }
        let config = "\(prefix)/etc/clamav/freshclam.conf"
        guard fm.fileExists(atPath: config) else {
            return .needsConfig(config)
        }
        return .ready
    }

    /// The Homebrew prefix the update runs against, if Homebrew is present.
    private var activePrefix: String? {
        prefixes.first { FileManager.default.isExecutableFile(atPath: "\($0)/bin/brew") }
    }

    /// The steps `run()` will execute, in order. Empty unless Homebrew exists.
    public var steps: [Step] {
        guard let prefix = activePrefix else { return [] }
        let brew = "\(prefix)/bin/brew"
        return [
            Step(title: "brew update", executable: brew, arguments: ["update"]),
            Step(title: "brew upgrade clamav", executable: brew,
                 arguments: ["upgrade", "clamav"]),
            Step(title: "freshclam", executable: "\(prefix)/bin/freshclam", arguments: []),
        ]
    }

    /// Environment for every step. PATH is explicit because launchd hands GUI
    /// apps a minimal one; the Homebrew variables keep brew from prompting or
    /// auto-updating a second time (step one already updates).
    func environment(prefix: String) -> [String: String] {
        [
            "PATH": "\(prefix)/bin:\(prefix)/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "NONINTERACTIVE": "1",
        ]
    }

    // MARK: - Running

    /// Runs every step in order, stopping at the first failure (the `&&`
    /// semantics of the shell one-liner). Cancelling the consuming task
    /// terminates the running subprocess.
    public func run() -> AsyncStream<Event> {
        let maintenance = self
        return AsyncStream { continuation in
            let task = Task {
                await maintenance.execute(continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(continuation: AsyncStream<Event>.Continuation) async {
        let started = Date()
        func finish(_ succeeded: Bool, _ message: String) {
            continuation.yield(.finished(Result(
                succeeded: succeeded, message: message,
                duration: Date().timeIntervalSince(started))))
        }

        guard let prefix = activePrefix else {
            finish(false, "Homebrew was not found.")
            return
        }
        let environment = environment(prefix: prefix)
        let steps = self.steps

        for (index, step) in steps.enumerated() {
            continuation.yield(.stepStarted(index: index, title: step.title))
            var lines: [String] = []
            var status: Int32 = -1

            do {
                let stream = try Subprocess.streamLines(
                    step.executable, arguments: step.arguments, environment: environment)
                for await event in stream {
                    switch event {
                    case .line(let line):
                        lines.append(line)
                        continuation.yield(.output(line))
                    case .exited(let code):
                        status = code
                    }
                }
            } catch {
                continuation.yield(.stepFinished(index: index, succeeded: false))
                finish(false, "\(step.title) could not start: \(error.localizedDescription)")
                return
            }

            if Task.isCancelled {
                continuation.yield(.stepFinished(index: index, succeeded: false))
                finish(false, "Stopped during \(step.title).")
                return
            }
            let succeeded = status == 0
            continuation.yield(.stepFinished(index: index, succeeded: succeeded))
            if !succeeded {
                finish(false, Self.failureMessage(step: step.title, status: status, lines: lines))
                return
            }
        }
        finish(true, "ClamAV and its signatures are up to date.")
    }

    /// Turns a failed step into one actionable sentence.
    static func failureMessage(step: String, status: Int32, lines: [String]) -> String {
        let joined = lines.joined(separator: "\n").lowercased()
        if step == "freshclam",
            joined.contains("locked by another process") || joined.contains("failed to lock")
                || joined.contains("can't lock")
        {
            return "freshclam is already running, for example as the Homebrew "
                + "service. Stop it with `brew services stop clamav` or wait for "
                + "it to finish, then try again."
        }
        if step == "freshclam",
            joined.contains("incorrect digital signature") || joined.contains("null x509 store")
        {
            return "freshclam could not verify the new signature database. This usually "
                + "means the installed ClamAV is out of date. If it still fails right "
                + "after the upgrade step, run `brew reinstall clamav` in Terminal."
        }
        // The first error line is usually the root cause ("Error: Failed to
        // download…"); tools close with generic lines like "Update failed.".
        let isError: (String) -> Bool = {
            let line = $0.lowercased()
            return line.hasPrefix("error") || line.hasPrefix("fatal")
        }
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let detail = nonEmpty.first(where: isError) ?? nonEmpty.last
        return "\(step) failed (exit \(status))" + (detail.map { ": \($0)" } ?? ".")
    }
}
