import Foundation

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

enum Subprocess {
    /// Runs `executablePath` synchronously and captures its output.
    /// Reads pipes before waiting so large output can't deadlock.
    static func run(_ executablePath: String, arguments: [String]) throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return SubprocessResult(
            status: process.terminationStatus, stdout: stdoutData, stderr: stderrData)
    }
}
