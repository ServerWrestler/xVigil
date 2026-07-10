import Darwin
import Foundation
import Testing
@testable import xVigilCore

@Suite struct QuarantineFileLocatorTests {
    private func makeQuarantinedFile(uuid: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent("download-\(UUID().uuidString).dmg")
        try Data("test".utf8).write(to: file)
        // Real xattr layout: flags;hex-timestamp;agent;event-UUID
        let xattr = "0083;686d3c1f;Chrome;\(uuid)"
        let result = xattr.withCString {
            setxattr(file.path, "com.apple.quarantine", $0, strlen($0), 0, 0)
        }
        #expect(result == 0)
        return file
    }

    @Test func locatesFileByEventUUID() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xvigil-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let uuid = UUID().uuidString
        let file = try makeQuarantinedFile(uuid: uuid, in: dir)
        _ = try makeQuarantinedFile(uuid: UUID().uuidString, in: dir)  // decoy

        // Compare resolved paths: the enumerator reports /private/var for
        // paths the test created via the /var symlink.
        let expected = file.resolvingSymlinksInPath().path
        let locator = QuarantineFileLocator(searchDirectories: [dir])
        #expect(locator.locate(eventID: uuid)?.resolvingSymlinksInPath().path == expected)
        // Case-insensitive match: the DB stores uppercase UUIDs.
        #expect(locator.locate(eventID: uuid.lowercased())?.resolvingSymlinksInPath().path == expected)
        #expect(locator.locate(eventID: UUID().uuidString) == nil)
    }

    @Test func readsEventIDFromXattr() throws {
        let dir = FileManager.default.temporaryDirectory
        let uuid = UUID().uuidString
        let file = try makeQuarantinedFile(uuid: uuid, in: dir)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(QuarantineFileLocator.quarantineEventID(of: file) == uuid)
    }

    @Test func fileWithoutXattrYieldsNil() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("clean-\(UUID().uuidString).txt")
        try Data("clean".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(QuarantineFileLocator.quarantineEventID(of: file) == nil)
    }
}

@Suite struct EnricherParsingTests {
    @Test func parsesSignedCodesignOutput() {
        let output = """
            Executable=/Applications/Test.app/Contents/MacOS/Test
            Identifier=com.example.test
            Format=app bundle with Mach-O universal (x86_64 arm64)
            Authority=Developer ID Application: Example Corp (ABCDE12345)
            Authority=Developer ID Certification Authority
            Authority=Apple Root CA
            Info.plist entries=23
            """
        let signature = EventEnricher.parseCodesign(status: 0, output: output)
        #expect(signature.status == .signed)
        #expect(signature.authorities.count == 3)
        #expect(signature.authorities.first == "Developer ID Application: Example Corp (ABCDE12345)")
    }

    @Test func recognizesUnsignedFiles() {
        let signature = EventEnricher.parseCodesign(
            status: 1,
            output: "/Users/x/Downloads/a.zip: code object is not signed at all")
        #expect(signature.status == .unsigned)
        #expect(signature.problem == nil)
    }

    @Test func reportsInvalidSignatures() {
        let signature = EventEnricher.parseCodesign(
            status: 1,
            output: "/Applications/Bad.app: invalid signature (code or signature have been modified)")
        #expect(signature.status == .invalid)
        #expect(signature.problem?.contains("invalid signature") == true)
    }

    @Test func extractsSpctlDetailLines() {
        let output = """
            /Applications/Test.app: accepted
            source=Notarized Developer ID
            origin=Developer ID Application: Example Corp (ABCDE12345)
            """
        let detail = EventEnricher.parseSpctlDetail(output)
        #expect(detail == "source=Notarized Developer ID\norigin=Developer ID Application: Example Corp (ABCDE12345)")
    }

    @Test func fallsBackToVerdictLine() {
        let detail = EventEnricher.parseSpctlDetail("/Users/x/a.dmg: rejected\n")
        #expect(detail == "/Users/x/a.dmg: rejected")
    }
}
