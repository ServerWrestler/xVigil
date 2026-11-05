import Foundation
import Observation
import xVigilScan

/// Drives the "Update ClamAV & signatures" button: exposes readiness, the
/// step list with per-step status, a capped live log, and the final result.
/// Report-only ethos still holds for scanning; this is the one place xVigil
/// runs package-management commands, and only when the user clicks.
@MainActor
@Observable
final class ClamAVUpdateController {
    struct StepState: Identifiable {
        enum Status { case pending, running, succeeded, failed }
        let id: Int
        let title: String
        var status: Status = .pending
    }

    private(set) var readiness: ClamAVMaintenance.Readiness
    private(set) var isRunning = false
    private(set) var steps: [StepState] = []
    private(set) var logLines: [String] = []
    private(set) var result: ClamAVMaintenance.Result?

    private let maintenance: ClamAVMaintenance
    private var task: Task<Void, Never>?

    /// The pane shows the tail of the log, not an unbounded transcript
    /// (brew can be chatty).
    private static let maxLogLines = 400

    init() {
        #if DEBUG
            // Lets the UI be exercised against a scripted fake Homebrew
            // prefix without touching the real install.
            if let fake = ProcessInfo.processInfo.environment["XVIGIL_FAKE_PREFIX"] {
                maintenance = ClamAVMaintenance(prefixes: [fake])
                readiness = maintenance.readiness()
                return
            }
        #endif
        maintenance = ClamAVMaintenance()
        readiness = maintenance.readiness()
    }

    func refreshReadiness() {
        guard !isRunning else { return }
        readiness = maintenance.readiness()
    }

    /// Starts the three-step update. `onFinished` runs on the main actor
    /// however the run ends, so the caller can re-check the engine.
    func start(onFinished: @escaping @MainActor () -> Void) {
        guard !isRunning, readiness == .ready else { return }
        isRunning = true
        result = nil
        logLines = []
        steps = maintenance.steps.enumerated().map {
            StepState(id: $0.offset, title: $0.element.title)
        }

        let maintenance = self.maintenance
        task = Task {
            for await event in maintenance.run() {
                handle(event)
            }
            // A cancelled consumer ends the stream without a .finished event.
            if result == nil {
                for index in steps.indices where steps[index].status == .running {
                    steps[index].status = .failed
                }
                result = ClamAVMaintenance.Result(
                    succeeded: false, message: "Stopped before finishing.", duration: 0)
            }
            isRunning = false
            task = nil
            readiness = maintenance.readiness()
            onFinished()
        }
    }

    /// Cancels the run; the running subprocess is terminated.
    func stop() {
        task?.cancel()
    }

    private func handle(_ event: ClamAVMaintenance.Event) {
        switch event {
        case .stepStarted(let index, _):
            steps[index].status = .running
        case .output(let line):
            logLines.append(line)
            if logLines.count > Self.maxLogLines {
                logLines.removeFirst(logLines.count - Self.maxLogLines)
            }
        case .stepFinished(let index, let succeeded):
            steps[index].status = succeeded ? .succeeded : .failed
        case .finished(let finished):
            result = finished
        }
    }
}
