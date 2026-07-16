import Foundation
import os

public struct SubprocessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    public var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
    /// stdout and stderr combined — some tools (spctl, codesign) split
    /// their report across both.
    public var combinedText: String { stdoutText + stderrText }
}

public enum SubprocessError: Error, LocalizedError {
    case timedOut(command: String, seconds: TimeInterval)

    public var errorDescription: String? {
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

public enum SubprocessStreamEvent: Sendable {
    case line(String)
    case exited(status: Int32)
}

/// Accumulates pipe data into lines and forwards them to an AsyncStream.
/// EOF and process exit race each other; the last of the two finishes the
/// stream so no output is dropped.
private final class LineStreamer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var sawEOF = false
    private var exitStatus: Int32?
    private var continuation: AsyncStream<SubprocessStreamEvent>.Continuation?

    func attach(_ continuation: AsyncStream<SubprocessStreamEvent>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            lines.append(Self.decode(lineData))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        let continuation = self.continuation
        lock.unlock()
        for line in lines { continuation?.yield(.line(line)) }
    }

    func eofReached() {
        lock.lock()
        sawEOF = true
        let remainder = buffer.isEmpty ? nil : Self.decode(buffer)
        buffer.removeAll()
        lock.unlock()
        if let remainder { continuation?.yield(.line(remainder)) }
        finishIfComplete()
    }

    func processExited(status: Int32) {
        lock.lock()
        exitStatus = status
        lock.unlock()
        finishIfComplete()
    }

    private func finishIfComplete() {
        lock.lock()
        guard sawEOF, let status = exitStatus, let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.yield(.exited(status: status))
        continuation.finish()
    }

    private static func decode(_ data: Data) -> String {
        var line = String(decoding: data, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }
}

public enum Subprocess {
    /// Runs `executablePath` synchronously. Blocks the calling thread — never
    /// call from the main thread or a Swift Concurrency cooperative thread;
    /// use `runAsync` from async contexts.
    public static func run(
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

    /// Streams stdout+stderr line by line as the process produces them —
    /// for long-running work (scans) that should render results live rather
    /// than after completion. The stream ends with `.exited(status:)`.
    /// Cancelling the consuming task terminates the process.
    public static func streamLines(
        _ executablePath: String,
        arguments: [String]
    ) throws -> AsyncStream<SubprocessStreamEvent> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        // One pipe for both: scan tools interleave findings and warnings,
        // and per-line ordering is all the consumer needs.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let streamer = LineStreamer()
        let box = ProcessBox(process)
        let stream = AsyncStream<SubprocessStreamEvent>(bufferingPolicy: .unbounded) { continuation in
            streamer.attach(continuation)
            continuation.onTermination = { reason in
                if case .cancelled = reason, box.process.isRunning {
                    box.process.terminate()
                }
            }
        }

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                streamer.eofReached()
            } else {
                streamer.consume(data)
            }
        }
        process.terminationHandler = { finished in
            streamer.processExited(status: finished.terminationStatus)
        }

        try process.run()
        return stream
    }

    /// Async variant that parks the blocking wait on a GCD thread. Long `log
    /// show` queries must never occupy the cooperative pool: its width is the
    /// CPU core count, and a few blocked threads starve every Task in the app.
    public static func runAsync(
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
