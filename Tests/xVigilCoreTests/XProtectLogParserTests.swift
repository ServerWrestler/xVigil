import Foundation
import Testing
@testable import xVigilCore

// Real-shaped ndjson lines as emitted by `log show --style ndjson`.
private let sampleNDJSON = """
    {"timestamp":"2026-07-10 14:23:40.899000-0400","eventMessage":"Got an event in libXPP dylib","processImagePath":"/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/XPCServices/XProtectBridgeService.xpc/Contents/MacOS/XProtectBridgeService","subsystem":"com.apple.XProtect","category":"behavior","messageType":"Debug"}
    not json at all
    {"timestamp":"2026-07-10 14:25:01.123456-0400","eventMessage":"malware detected: OSX.Trojan.Test","processImagePath":"/usr/libexec/XProtectService","subsystem":"com.apple.XProtect","category":"detection","messageType":"Error"}
    {"timestamp":"2026-07-10 14:26:02.000000-0400","eventMessage":"App gets first launch prompt because responsibility=1, assessment denied","processImagePath":"/usr/libexec/syspolicyd","subsystem":"com.apple.syspolicy.exec","category":"default","messageType":"Default"}
    {"timestamp":"bad-timestamp","eventMessage":"scan started for module TrojanHunter","processImagePath":"/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/MacOS/XProtectRemediatorTrojanHunter","subsystem":"com.apple.XProtectFramework.PluginAPI","category":"scan","messageType":"Info"}
    {"eventMessage":null,"processImagePath":"/usr/libexec/XProtectService"}
    """

@Suite struct XProtectLogParserTests {
    @Test func parsesValidLinesAndSkipsJunk() {
        let entries = XProtectLogParser.parse(ndjson: sampleNDJSON)
        // 5 JSON lines, but one has a null eventMessage and one line isn't JSON.
        #expect(entries.count == 4)
    }

    @Test func extractsFields() throws {
        let entry = try #require(XProtectLogParser.parse(ndjson: sampleNDJSON).first)

        #expect(entry.process == "XProtectBridgeService")
        #expect(entry.subsystem == "com.apple.XProtect")
        #expect(entry.category == "behavior")
        #expect(entry.level == "Debug")
        #expect(entry.message == "Got an event in libXPP dylib")
        #expect(entry.date != nil)
    }

    @Test func parsesUnifiedLogTimestamps() throws {
        let entry = try #require(XProtectLogParser.parse(ndjson: sampleNDJSON).first)
        let date = try #require(entry.date)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -4 * 3600)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 7)
        #expect(parts.day == 10)
        #expect(parts.hour == 14)
        #expect(parts.minute == 23)
        #expect(parts.second == 40)
    }

    @Test func badTimestampYieldsNilDateNotDroppedEntry() {
        let entries = XProtectLogParser.parse(ndjson: sampleNDJSON)
        let scan = entries.first { $0.message.contains("scan started") }
        #expect(scan != nil)
        #expect(scan?.date == nil)
    }

    @Test func classifiesEntries() {
        let entries = XProtectLogParser.parse(ndjson: sampleNDJSON)
        let kinds = Dictionary(grouping: entries, by: \.kind)

        #expect(kinds[.detection]?.count == 1)
        #expect(kinds[.assessment]?.count == 1)
        #expect(kinds[.scan]?.count == 1)
        #expect(kinds[.activity]?.count == 1)
    }
}
