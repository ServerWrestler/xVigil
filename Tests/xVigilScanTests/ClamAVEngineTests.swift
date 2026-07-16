import Foundation
import Testing
@testable import xVigilScan

@Suite struct ClamAVOutputParsingTests {
    @Test func parsesThreatLines() {
        let parsed = ClamAVEngine.parseLine("/Users/x/Downloads/eicar.txt: Eicar-Signature FOUND")
        #expect(parsed == .threat(path: "/Users/x/Downloads/eicar.txt", signature: "Eicar-Signature"))
    }

    @Test func pathsContainingColonsParse() {
        let parsed = ClamAVEngine.parseLine("/tmp/odd: name/file.zip: Osx.Malware.Agent FOUND")
        #expect(parsed == .threat(path: "/tmp/odd: name/file.zip", signature: "Osx.Malware.Agent"))
    }

    @Test func okAndSummaryLinesAreNoise() {
        #expect(ClamAVEngine.parseLine("/tmp/fine.txt: OK") == .noise)
        #expect(ClamAVEngine.parseLine("----------- SCAN SUMMARY -----------") == .noise)
        #expect(ClamAVEngine.parseLine("Infected files: 0") == .noise)
        #expect(ClamAVEngine.parseLine("Time: 12.3 sec (0 m 12 s)") == .noise)
        #expect(ClamAVEngine.parseLine("") == .noise)
    }

    @Test func scannedCountExtracted() {
        #expect(ClamAVEngine.parseLine("Scanned files: 1234") == .scannedCount(1234))
    }

    @Test func warningsSurfaceAsOther() {
        let parsed = ClamAVEngine.parseLine("WARNING: Can't open file /private/etc/foo: Permission denied")
        #expect(parsed == .other("WARNING: Can't open file /private/etc/foo: Permission denied"))
    }
}

@Suite struct ClamAVEngineIntegrationTests {
    /// Full pipeline test against a fake clamscan that emits real-shaped
    /// output: streaming, parsing, summary, and exit-code handling — no
    /// ClamAV install required.
    @Test func scansViaFakeScanner() async throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-clamscan-\(UUID().uuidString).sh")
        try """
            #!/bin/sh
            echo "/tmp/target/clean.txt: OK"
            echo "/tmp/target/bad.zip: Osx.Trojan.Fake FOUND"
            echo "/tmp/target/worse.dmg: Eicar-Test-Signature FOUND"
            echo ""
            echo "----------- SCAN SUMMARY -----------"
            echo "Scanned files: 3"
            echo "Infected files: 2"
            exit 1
            """.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)

        let engine = ClamAVEngine(clamscan: script)
        var threats: [(String, String)] = []
        var summary: ScanSummary?
        for await event in engine.scan(paths: [URL(fileURLWithPath: "/tmp/target")]) {
            switch event {
            case .threatFound(let path, let signature):
                threats.append((path, signature))
            case .finished(let s):
                summary = s
            case .started, .progress:
                break
            }
        }

        #expect(threats.count == 2)
        #expect(threats.first?.1 == "Osx.Trojan.Fake")
        let finalSummary = try #require(summary)
        #expect(finalSummary.infectedCount == 2)
        #expect(finalSummary.scannedCount == 3)
        #expect(finalSummary.exitStatus == 1)
        #expect(finalSummary.errorMessage == nil)
    }

    @Test func missingEngineFailsGracefully() async {
        let engine = ClamAVEngine(
            clamdscan: URL(fileURLWithPath: "/nonexistent/clamdscan"),
            clamscan: URL(fileURLWithPath: "/nonexistent/clamscan"))
        var summary: ScanSummary?
        for await event in engine.scan(paths: [URL(fileURLWithPath: "/tmp")]) {
            if case .finished(let s) = event { summary = s }
        }
        #expect(summary != nil)
        #expect(summary?.errorMessage != nil)
        #expect(summary?.infectedCount == 0)
    }

    @Test func signatureAgeReadsNewestDatabaseFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-clamav-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let old = dir.appendingPathComponent("main.cvd")
        let fresh = dir.appendingPathComponent("daily.cld")
        try Data("x".utf8).write(to: old)
        try Data("x".utf8).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -30 * 86_400)],
            ofItemAtPath: old.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: fresh.path)

        let engine = ClamAVEngine(databaseDirectory: dir)
        let age = engine.signatureDatabaseAge(scannerPath: nil)
        #expect(age != nil)
        // Newest file wins: ~1h, definitely under a day.
        #expect(age! < 86_400)
    }
}
