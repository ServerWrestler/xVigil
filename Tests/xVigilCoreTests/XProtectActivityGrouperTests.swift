import Foundation
import Testing
@testable import xVigilCore

private func entry(
    _ offsetSeconds: TimeInterval?,
    process: String,
    message: String = "routine chatter"
) -> XProtectLogEntry {
    let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
    return XProtectLogEntry(
        date: offsetSeconds.map { base.addingTimeInterval($0) },
        process: process,
        subsystem: "com.apple.XProtect",
        category: "test",
        level: "Default",
        message: message
    )
}

@Suite struct XProtectActivityGrouperTests {
    @Test func groupsConsecutiveEntriesFromOneProcess() {
        let activities = XProtectActivityGrouper.group([
            entry(0, process: "XProtectService"),
            entry(5, process: "XProtectService"),
            entry(12, process: "XProtectService"),
        ])
        #expect(activities.count == 1)
        #expect(activities[0].entries.count == 3)
        #expect(activities[0].process == "XProtectService")
    }

    @Test func splitsOnTimeGap() {
        let activities = XProtectActivityGrouper.group(
            [
                entry(0, process: "XProtectService"),
                entry(10, process: "XProtectService"),
                entry(200, process: "XProtectService"),
            ],
            maxGap: 30
        )
        #expect(activities.count == 2)
        #expect(activities[0].entries.count == 2)
        #expect(activities[1].entries.count == 1)
    }

    @Test func mergesInterleavedProcessesWithinGap() {
        // A scan run interleaves several cooperating processes — they belong
        // to one activity, titled by the most talkative process.
        let activities = XProtectActivityGrouper.group([
            entry(0, process: "XProtectService"),
            entry(1, process: "XProtectPluginService"),
            entry(2, process: "XProtectService"),
        ])
        #expect(activities.count == 1)
        #expect(activities[0].process == "XProtectService")
    }

    @Test func nilDateEntriesInheritCurrentCluster() {
        let activities = XProtectActivityGrouper.group([
            entry(0, process: "XProtectService"),
            entry(nil, process: "XProtectService"),
            entry(5, process: "XProtectService"),
        ])
        #expect(activities.count == 1)
        #expect(activities[0].entries.count == 3)
    }

    @Test func summarizesWithMostSevereKind() {
        let activities = XProtectActivityGrouper.group([
            entry(0, process: "XProtectService", message: "scan started"),
            entry(1, process: "XProtectService", message: "malware detected: OSX.Test"),
            entry(2, process: "XProtectService", message: "routine chatter"),
        ])
        #expect(activities.count == 1)
        #expect(activities[0].kind == .detection)
        #expect(activities[0].flaggedEntries.count == 1)
    }

    @Test func computesDateRange() {
        let activities = XProtectActivityGrouper.group([
            entry(3, process: "XProtectService"),
            entry(9, process: "XProtectService"),
        ])
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(activities[0].startDate == base.addingTimeInterval(3))
        #expect(activities[0].endDate == base.addingTimeInterval(9))
    }

    @Test func emptyInputYieldsNoActivities() {
        #expect(XProtectActivityGrouper.group([]).isEmpty)
    }
}
