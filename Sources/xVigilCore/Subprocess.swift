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
        let continuation = self.continuation
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

    /// Fully non-blocking async run: collects output via readability handlers
    /// and resumes on the process's termination handler, so a subprocess
    /// occupies **zero** worker threads while it runs. The previous
    /// implementation blocked three `.userInitiated` GCD threads per call
    /// (the wait plus two pipe drains); several concurrent `log show` queries
    /// then starved the pool, and a freshly-clicked event's enrich walk or
    /// log query could never get scheduled — both detail fields spun forever.
    public static func runAsync(
        _ executablePath: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) async throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector()
        let commandName = URL(fileURLWithPath: executablePath).lastPathComponent

        return try await withCheckedThrowingContinuation { continuation in
            collector.attach(continuation, command: commandName, timeout: timeout ?? 0)

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    collector.finishStdout()
                } else {
                    collector.appendStdout(data)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    collector.finishStderr()
                } else {
                    collector.appendStderr(data)
                }
            }
            process.terminationHandler = { finished in
                collector.processExited(status: finished.terminationStatus)
            }

            if let timeout {
                let box = ProcessBox(process)
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    collector.markTimedOut()
                    if box.process.isRunning { box.process.terminate() }
                }
                timer.activate()
                collector.retainTimer(timer)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                collector.disarm()
            }
        }
    }
}

/// Accumulates a subprocess's stdout/stderr from readability handlers and
/// resumes the continuation once the process has exited AND both pipes have
/// hit EOF — so no trailing output is lost. Thread-safe; no blocked threads.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var outEOF = false
    private var errEOF = false
    private var exitStatus: Int32?
    private var timedOut = false
    private var resumed = false
    private var continuation: CheckedContinuation<SubprocessResult, Error>?
    private var command = ""
    private var timeout: TimeInterval = 0
    private var timer: DispatchSourceTimer?

    func attach(
        _ continuation: CheckedContinuation<SubprocessResult, Error>,
        command: String, timeout: TimeInterval
    ) {
        lock.lock()
        self.continuation = continuation
        self.command = command
        self.timeout = timeout
        lock.unlock()
    }

    func retainTimer(_ timer: DispatchSourceTimer) {
        lock.lock(); self.timer = timer; lock.unlock()
    }

    func appendStdout(_ data: Data) { lock.lock(); out.append(data); lock.unlock() }
    func appendStderr(_ data: Data) { lock.lock(); err.append(data); lock.unlock() }
    func finishStdout() { lock.lock(); outEOF = true; lock.unlock(); resumeIfComplete() }
    func finishStderr() { lock.lock(); errEOF = true; lock.unlock(); resumeIfComplete() }
    func processExited(status: Int32) {
        lock.lock(); exitStatus = status; lock.unlock(); resumeIfComplete()
    }
    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }

    /// Called if `process.run()` throws — nothing will ever complete.
    func disarm() {
        lock.lock(); resumed = true; timer?.cancel(); timer = nil; lock.unlock()
    }

    private func resumeIfComplete() {
        lock.lock()
        guard !resumed, exitStatus != nil, outEOF, errEOF,
            let continuation else { lock.unlock(); return }
        resumed = true
        timer?.cancel()
        timer = nil
        let result = SubprocessResult(status: exitStatus!, stdout: out, stderr: err)
        let didTimeOut = timedOut
        let command = command
        let timeout = timeout
        self.continuation = nil
        lock.unlock()

        if didTimeOut {
            continuation.resume(throwing: SubprocessError.timedOut(
                command: command, seconds: timeout))
        } else {
            continuation.resume(returning: result)
        }
    }
}
