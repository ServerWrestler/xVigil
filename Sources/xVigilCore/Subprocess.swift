import Foundation
import os

struct SubprocessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
    /// stdout and stderr combined — some tools (spctl, codesign) split
    /// their report across both.
    var combinedText: String { stdoutText + stderrText }
}

enum SubprocessError: Error, LocalizedError {
    case timedOut(command: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let command, let seconds):
            "\(command) did not finish within \(Int(seconds))s and was terminated"
        }
    }
}

/// Drains one pipe on a background thread. Each pipe needs its own reader:
/// a child that fills pipe B while we block reading pipe A deadlocks both.
private final class PipeDrain: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.data = handle.readDataToEndOfFile()
            self.done.signal()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}

/// Process isn't Sendable; the timeout handler only calls terminate(),
/// which is safe from any thread.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

enum Subprocess {
    /// Runs `executablePath` synchronously. Blocks the calling thread — never
    /// call from the main thread or a Swift Concurrency cooperative thread;
    /// use `runAsync` from async contexts.
    static func run(
        _ executablePath: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let stdoutDrain = PipeDrain(stdoutPipe.fileHandleForReading)
        let stderrDrain = PipeDrain(stderrPipe.fileHandleForReading)

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        var timer: DispatchSourceTimer?
        if let timeout {
            let box = ProcessBox(process)
            let source = DispatchSource.makeTimerSource(queue: .global())
            source.schedule(deadline: .now() + timeout)
            source.setEventHandler {
                timedOut.withLock { $0 = true }
                box.process.terminate()
            }
            source.activate()
            timer = source
        }

        process.waitUntilExit()
        timer?.cancel()
        let stdout = stdoutDrain.wait()
        let stderr = stderrDrain.wait()

        if timedOut.withLock({ $0 }) {
            throw SubprocessError.timedOut(
                command: URL(fileURLWithPath: executablePath).lastPathComponent,
                seconds: timeout ?? 0)
        }
        return SubprocessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// Async variant that parks the blocking wait on a GCD thread. Long `log
    /// show` queries must never occupy the cooperative pool: its width is the
    /// CPU core count, and a few blocked threads starve every Task in the app.
    static func runAsync(
        _ executablePath: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) async throws -> SubprocessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try run(executablePath, arguments: arguments, timeout: timeout)
                })
            }
        }
    }
}
