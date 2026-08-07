import Foundation
import Testing

@testable import xVigilCore

@Suite struct WatchlistCheckerTests {
    /// Runs a synchronous single-entry check and returns (state, findings).
    private func run(
        _ entry: WatchlistEntry,
        prior: WatchlistCheckState = WatchlistCheckState()
    ) -> (state: WatchlistCheckState, findings: [WatchlistFinding]) {
        var findings: [WatchlistFinding] = []
        let state = WatchlistChecker.checkEntry(entry, prior: prior) { findings.append($0) }
        return (state, findings)
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xvigil-checker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Literal paths

    @Test func literalPathExists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("present.txt")
        try Data("hello".utf8).write(to: file)

        let (_, findings) = run(WatchlistEntry(target: file.path, label: "present"))
        #expect(findings.count == 1)
        #expect(findings[0].exists)
        // Plain existence entry defaults to onPresence: found ⇒ alert.
        #expect(findings[0].isAlert)
    }

    @Test func literalPathMissing() {
        let (_, findings) = run(WatchlistEntry(
            target: "/nonexistent/xvigil-test-\(UUID().uuidString)", label: "missing"))
        #expect(findings.count == 1)
        #expect(!findings[0].exists)
        // onPresence (the default) does not fire for a missing file.
        #expect(!findings[0].isAlert)
    }

    @Test func onAbsenceAlertsForMissingLiteral() {
        let (_, findings) = run(WatchlistEntry(
            target: "/nonexistent/xvigil-test-\(UUID().uuidString)", label: "sentinel",
            alertConditions: [.onAbsence]))
        #expect(findings.count == 1)
        #expect(findings[0].isAlert)
    }

    @Test func tildeExpansion() {
        // "~" must expand to the real home directory, which exists.
        let (_, findings) = run(WatchlistEntry(
            target: "~", label: "home", recursive: false))
        // Home is a directory: shallow enumeration of regular files.
        // Whatever it contains, nothing should carry a tilde path.
        #expect(findings.allSatisfy { !$0.path.hasPrefix("~") })
    }

    // MARK: Glob resolution

    @Test func globMatchesExtension() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.plist"))
        try Data().write(to: dir.appendingPathComponent("b.plist"))
        try Data().write(to: dir.appendingPathComponent("c.txt"))

        let (_, findings) = run(WatchlistEntry(
            target: dir.appendingPathComponent("*.plist").path, label: "plists"))
        #expect(findings.count == 2)
        #expect(findings.allSatisfy { $0.path.hasSuffix(".plist") })
    }

    @Test func globNoMatchIsSilent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (_, findings) = run(WatchlistEntry(
            target: dir.appendingPathComponent("*.nope").path, label: "none"))
        // A glob that matches nothing is the good outcome — no findings.
        #expect(findings.isEmpty)
    }

    @Test func recursiveVersusShallow() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("top.plist"))
        try Data().write(to: nested.appendingPathComponent("deep.plist"))

        let glob = dir.appendingPathComponent("*.plist").path
        let (_, shallow) = run(WatchlistEntry(target: glob, label: "s", recursive: false))
        #expect(shallow.count == 1)

        let (_, deep) = run(WatchlistEntry(target: glob, label: "d", recursive: true))
        #expect(deep.count == 2)
    }

    // MARK: Integrity

    @Test func integrityBaselineThenChange() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("watched.conf")
        try Data("version 1".utf8).write(to: file)

        let entry = WatchlistEntry(
            target: file.path, label: "conf", trackIntegrity: true)

        // First sight: baseline recorded, hashChanged is nil (not a change).
        let (state1, findings1) = run(entry)
        #expect(findings1[0].hashChanged == nil)
        #expect(!findings1[0].isAlert)  // onChange default; no change yet
        #expect(state1.baselineHashes[file.path] != nil)

        // Unchanged content: hashChanged == false.
        let (state2, findings2) = run(entry, prior: state1)
        #expect(findings2[0].hashChanged == false)
        #expect(!findings2[0].isAlert)

        // Changed content: hashChanged == true, and onChange fires.
        try Data("version 2".utf8).write(to: file)
        let (_, findings3) = run(entry, prior: state2)
        #expect(findings3[0].hashChanged == true)
        #expect(findings3[0].isAlert)
    }

    @Test func perPathBaselinesForMultiFileEntries() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("aaa".utf8).write(to: dir.appendingPathComponent("a.plist"))
        try Data("bbb".utf8).write(to: dir.appendingPathComponent("b.plist"))

        let entry = WatchlistEntry(
            target: dir.appendingPathComponent("*.plist").path,
            label: "many", trackIntegrity: true)
        let (state, _) = run(entry)
        // One baseline per resolved file — the reason baselines are a dict.
        #expect(state.baselineHashes.count == 2)

        // Change one file: only that file reports changed.
        try Data("AAA".utf8).write(to: dir.appendingPathComponent("a.plist"))
        let (_, findings) = run(entry, prior: state)
        let changed = findings.filter { $0.hashChanged == true }
        let unchanged = findings.filter { $0.hashChanged == false }
        #expect(changed.count == 1)
        #expect(changed[0].path.hasSuffix("a.plist"))
        #expect(unchanged.count == 1)
    }

    // MARK: Content scanning

    @Test func contentPatternMatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agent.plist")
        try Data("<string>https://evil.com/beacon</string>".utf8).write(to: file)

        let entry = WatchlistEntry(
            target: file.path, label: "agent",
            contentPatterns: ["evil\\.com", "unrelated"])
        let (_, findings) = run(entry)
        #expect(findings[0].matchedPatterns == ["evil\\.com"])
        #expect(findings[0].isAlert)  // onMatch default fires
    }

    @Test func contentPatternNoMatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clean.txt")
        try Data("nothing suspicious".utf8).write(to: file)

        let entry = WatchlistEntry(
            target: file.path, label: "clean", contentPatterns: ["evil\\.com"])
        let (_, findings) = run(entry)
        #expect(findings[0].matchedPatterns.isEmpty)
        #expect(!findings[0].isAlert)
    }

    @Test func invalidRegexRecordedAndPassContinues() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("data.txt")
        try Data("evil.com".utf8).write(to: file)

        let entry = WatchlistEntry(
            target: file.path, label: "mixed",
            contentPatterns: ["([unclosed", "evil\\.com"])
        let (_, findings) = run(entry)
        // One error finding for the bad pattern + one real finding.
        #expect(findings.count == 2)
        #expect(findings[0].error?.contains("invalid pattern") == true)
        #expect(findings[1].matchedPatterns == ["evil\\.com"])
    }

    @Test func oversizedFileSkipsContentScan() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.log")
        try Data(repeating: 0x61, count: WatchlistChecker.maxContentScanBytes + 1)
            .write(to: file)

        let entry = WatchlistEntry(
            target: file.path, label: "big", contentPatterns: ["a"])
        let (_, findings) = run(entry)
        #expect(findings[0].error == "file too large, skipped content scan")
        #expect(findings[0].matchedPatterns.isEmpty)
    }

    @Test func binaryFileSkipsContentScan() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("binary.bin")
        var bytes = Data("evil.com".utf8)
        bytes.append(0)  // NUL byte ⇒ binary sniff trips
        try bytes.write(to: file)

        let entry = WatchlistEntry(
            target: file.path, label: "bin", contentPatterns: ["evil\\.com"])
        let (_, findings) = run(entry)
        #expect(findings[0].matchedPatterns.isEmpty)
        #expect(findings[0].error == nil)
    }

    // MARK: Caps

    @Test func resolutionCapTruncates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<(WatchlistChecker.maxResolvedFiles + 10) {
            try Data().write(to: dir.appendingPathComponent("f\(index).txt"))
        }

        let entry = WatchlistEntry(
            target: dir.appendingPathComponent("*.txt").path, label: "flood")
        let (_, findings) = run(entry)
        let truncation = findings.filter { $0.error?.contains("truncated") == true }
        #expect(truncation.count == 1)
        #expect(findings.count == WatchlistChecker.maxResolvedFiles + 1)
    }

    // MARK: Alert-condition defaulting

    @Test func defaultingRules() {
        #expect(WatchlistEntry(target: "/a", label: "plain")
            .alertConditions == [.onPresence])
        #expect(WatchlistEntry(target: "/a", label: "hash", trackIntegrity: true)
            .alertConditions == [.onChange])
        #expect(WatchlistEntry(target: "/a", label: "rx", contentPatterns: ["x"])
            .alertConditions == [.onMatch])
        #expect(WatchlistEntry(
            target: "/a", label: "both", trackIntegrity: true, contentPatterns: ["x"])
            .alertConditions == [.onChange, .onMatch])
    }
}
