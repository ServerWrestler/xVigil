import Foundation
import Testing
@testable import xVigilScan

/// A throwaway Homebrew prefix: `<root>/bin/brew`, `<root>/bin/freshclam`,
/// `<root>/etc/clamav/freshclam.conf`, with scripted behavior, so the real
/// install is never touched.
private struct FakePrefix {
    let root: URL

    init(
        brew: String? = "echo \"brew $*\"",
        freshclam: String? = "echo freshclam-ran",
        config: Bool = true
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xvigil-prefix-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: root.appendingPathComponent("etc/clamav"), withIntermediateDirectories: true)
        if let brew { try install(brew, as: "brew") }
        if let freshclam { try install(freshclam, as: "freshclam") }
        if config {
            try Data("DatabaseMirror database.clamav.net\n".utf8).write(
                to: root.appendingPathComponent("etc/clamav/freshclam.conf"))
        }
    }

    private func install(_ body: String, as name: String) throws {
        let url = root.appendingPathComponent("bin/\(name)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    var maintenance: ClamAVMaintenance { ClamAVMaintenance(prefixes: [root.path]) }
}

private struct Outcome {
    var started: [String] = []
    var output: [String] = []
    var finished: [(index: Int, succeeded: Bool)] = []
    var result: ClamAVMaintenance.Result?
}

private func collect(_ maintenance: ClamAVMaintenance) async -> Outcome {
    var outcome = Outcome()
    for await event in maintenance.run() {
        switch event {
        case .stepStarted(_, let title): outcome.started.append(title)
        case .output(let line): outcome.output.append(line)
        case .stepFinished(let index, let succeeded):
            outcome.finished.append((index, succeeded))
        case .finished(let result): outcome.result = result
        }
    }
    return outcome
}

@Suite struct ClamAVMaintenanceReadinessTests {
    @Test func readyWhenBrewFreshclamAndConfigExist() throws {
        let prefix = try FakePrefix()
        defer { prefix.remove() }
        #expect(prefix.maintenance.readiness() == .ready)
    }

    @Test func reportsMissingHomebrew() throws {
        let prefix = try FakePrefix(brew: nil)
        defer { prefix.remove() }
        #expect(prefix.maintenance.readiness()
            == .missing(homebrewMissing: true, clamavMissing: false))
    }

    @Test func reportsMissingClamAV() throws {
        let prefix = try FakePrefix(freshclam: nil)
        defer { prefix.remove() }
        #expect(prefix.maintenance.readiness()
            == .missing(homebrewMissing: false, clamavMissing: true))
    }

    @Test func reportsBothMissing() throws {
        let prefix = try FakePrefix(brew: nil, freshclam: nil)
        defer { prefix.remove() }
        #expect(prefix.maintenance.readiness()
            == .missing(homebrewMissing: true, clamavMissing: true))
    }

    @Test func reportsMissingFreshclamConfig() throws {
        let prefix = try FakePrefix(config: false)
        defer { prefix.remove() }
        let expected = prefix.root.appendingPathComponent("etc/clamav/freshclam.conf").path
        #expect(prefix.maintenance.readiness() == .needsConfig(expected))
    }

    @Test func noPrefixAtAllMeansBothMissing() {
        let maintenance = ClamAVMaintenance(prefixes: ["/nonexistent/prefix"])
        #expect(maintenance.readiness()
            == .missing(homebrewMissing: true, clamavMissing: true))
        #expect(maintenance.steps.isEmpty)
    }
}

@Suite struct ClamAVMaintenanceRunTests {
    @Test func plansExactlyTheThreeRequestedSteps() throws {
        let prefix = try FakePrefix()
        defer { prefix.remove() }
        #expect(prefix.maintenance.steps.map(\.title)
            == ["brew update", "brew upgrade clamav", "freshclam"])
    }

    @Test func runsAllStepsInOrderAndReportsSuccess() async throws {
        let prefix = try FakePrefix()
        defer { prefix.remove() }
        let outcome = await collect(prefix.maintenance)

        #expect(outcome.started == ["brew update", "brew upgrade clamav", "freshclam"])
        #expect(outcome.finished.map(\.succeeded) == [true, true, true])
        // Output streamed through, and brew got the right arguments:
        // clamav only, never a bare `brew upgrade`.
        #expect(outcome.output.contains("brew update"))
        #expect(outcome.output.contains("brew upgrade clamav"))
        #expect(outcome.output.contains("freshclam-ran"))
        #expect(outcome.result?.succeeded == true)
    }

    @Test func stopsAtFirstFailureLikeAndAnd() async throws {
        // `brew update` fails: upgrade and freshclam must never run.
        let prefix = try FakePrefix(
            brew: "if [ \"$1\" = update ]; then echo 'network down'; exit 1; fi; echo \"brew $*\"")
        defer { prefix.remove() }
        let outcome = await collect(prefix.maintenance)

        #expect(outcome.started == ["brew update"])
        #expect(outcome.finished.map(\.succeeded) == [false])
        #expect(!outcome.output.contains("freshclam-ran"))
        #expect(outcome.result?.succeeded == false)
        #expect(outcome.result?.message.contains("brew update failed") == true)
        #expect(outcome.result?.message.contains("network down") == true)
    }

    @Test func laterFailureStopsRemainingSteps() async throws {
        let prefix = try FakePrefix(freshclam: "echo 'boom'; exit 2")
        defer { prefix.remove() }
        let outcome = await collect(prefix.maintenance)
        #expect(outcome.started.count == 3)
        #expect(outcome.finished.map(\.succeeded) == [true, true, false])
        #expect(outcome.result?.succeeded == false)
    }

    @Test func freshclamLockGetsAnActionableMessage() async throws {
        let prefix = try FakePrefix(
            freshclam: "echo 'ERROR: freshclam.dat is locked by another process'; exit 1")
        defer { prefix.remove() }
        let outcome = await collect(prefix.maintenance)
        #expect(outcome.result?.succeeded == false)
        #expect(outcome.result?.message.contains("brew services stop clamav") == true)
    }

    @Test func signatureVerificationFailureExplainsOutdatedClamAV() async throws {
        // The real failure seen on a machine with an outdated ClamAV.
        let prefix = try FakePrefix(freshclam: """
            echo 'WARNING: [LibClamAV] cli_loadinfo: Incorrect digital signature'
            echo 'ERROR: Database test FAILED.'
            echo 'ERROR: Update failed.'
            exit 8
            """)
        defer { prefix.remove() }
        let outcome = await collect(prefix.maintenance)
        #expect(outcome.result?.succeeded == false)
        #expect(outcome.result?.message.contains("out of date") == true)
        #expect(outcome.result?.message.contains("brew reinstall clamav") == true)
    }

    @Test func failureMessageNamesTheRootCauseNotTheGenericClosingLine() {
        let message = ClamAVMaintenance.failureMessage(
            step: "brew update", status: 1,
            lines: ["==> Updating Homebrew...", "Error: Failed to download tap",
                    "Something else", "Update failed."])
        #expect(message.contains("Failed to download tap"))
        #expect(!message.contains("Update failed."))
    }

    @Test func stepsGetExplicitPathAndNonInteractiveEnvironment() async throws {
        let prefix = try FakePrefix(
            brew: "echo \"PATH=$PATH\"; echo \"NI=$NONINTERACTIVE\"; echo \"AU=$HOMEBREW_NO_AUTO_UPDATE\"")
        defer { prefix.remove() }
        let outcome = await collect(prefix.maintenance)

        let pathLine = outcome.output.first { $0.hasPrefix("PATH=") } ?? ""
        #expect(pathLine.contains("\(prefix.root.path)/bin"))
        #expect(pathLine.contains("/usr/bin"))
        #expect(outcome.output.contains("NI=1"))
        #expect(outcome.output.contains("AU=1"))
    }

    @Test func cancellingTerminatesTheRunningStep() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("xvigil-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        // brew update hangs; if cancellation fails to kill it, the marker
        // is written after the sleep.
        let prefix = try FakePrefix(brew: "sleep 4; touch '\(marker.path)'")
        defer { prefix.remove() }

        let started = Date()
        let task = Task { await collect(prefix.maintenance) }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        let outcome = await task.value

        // A cancelled consumer simply stops receiving events, so no
        // `.finished` arrives: reporting "stopped" is the caller's job.
        #expect(Date().timeIntervalSince(started) < 3.5)
        #expect(outcome.result == nil)
        #expect(outcome.started == ["brew update"])  // later steps never began
        try await Task.sleep(for: .seconds(4.5))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
