import Foundation
import xVigilCore

// Prototype harness for the data layer. Usage:
//   swift run xvigil-cli status
//   swift run xvigil-cli quarantine [limit]
//   swift run xvigil-cli agents
//   swift run xvigil-cli xprotect-log [window]   (window: 30m, 2h, 1d, ...)

let timestampFormat = Date.FormatStyle(date: .abbreviated, time: .standard)

func printUsageAndExit() -> Never {
    print("""
        usage: xvigil-cli <command>

        commands:
          status                 Gatekeeper + XProtect version info
          quarantine [limit]     Recent quarantine events (default 20)
          agents                 Quarantine event counts by downloading app
          xprotect-log [window]  Parsed XProtect/Gatekeeper unified log entries (default 1h)
          activities [window]    Log entries grouped into activities (default 6h)
          enrich [event-id]      Locate file + Gatekeeper/codesign verdict (default: newest event)
        """)
    exit(64)
}

func runStatus() {
    let status = SystemStatus.current()
    let gatekeeper = switch status.gatekeeperEnabled {
    case true: "enabled"
    case false: "DISABLED"
    default: "unknown"
    }
    print("Gatekeeper:           \(gatekeeper)")
    print("XProtect definitions: \(status.xprotectVersion ?? "unknown")")
    print("XProtect Remediator:  \(status.remediatorVersion ?? "not found")")
}

func runQuarantine(limit: Int) throws {
    let store = QuarantineStore()
    let events = try store.recentEvents(limit: limit)
    print("Total events on record: \(try store.eventCount())\n")
    for event in events {
        let when = event.timestamp.map { $0.formatted(timestampFormat) } ?? "unknown time"
        let source = event.dataURL ?? event.originURL ?? "no URL recorded"
        print("[\(when)] \(event.agentName ?? "?") — \(event.kind.label)")
        print("    \(source)")
    }
}

func runAgents() throws {
    for (agent, count) in try QuarantineStore().countsByAgent() {
        print(String(format: "%6d  %@", count, agent))
    }
}

func runXProtectLog(window: String) async throws {
    let entries = try await XProtectLogReader().entries(last: window)
    print("Parsed \(entries.count) entries from the last \(window)\n")
    for entry in entries {
        let when = entry.date.map { $0.formatted(timestampFormat) } ?? "?"
        let tag = entry.kind == .activity ? "" : " [\(entry.kind.rawValue.uppercased())]"
        print("[\(when)] \(entry.process) (\(entry.category ?? "-"))\(tag)")
        print("    \(entry.message)")
    }
    let interesting = entries.filter { $0.kind != .activity }
    if !interesting.isEmpty {
        print("\n\(interesting.count) entries flagged as detection/assessment/scan")
    }
}

func runActivities(window: String) async throws {
    let entries = try await XProtectLogReader().entries(last: window)
    let activities = XProtectActivityGrouper.group(entries)
    print("\(entries.count) entries → \(activities.count) activities in the last \(window)\n")
    for activity in activities {
        let start = activity.startDate.map { $0.formatted(timestampFormat) } ?? "?"
        let tag = activity.kind == .activity ? "" : "  [\(activity.kind.label)]"
        print("[\(start)] \(activity.process) — \(activity.entries.count) entries\(tag)")
        for flagged in activity.flaggedEntries.prefix(3) {
            print("    \(flagged.message.prefix(120))")
        }
    }
}

func runEnrich(eventID: String?) async throws {
    let store = QuarantineStore()
    let event: QuarantineEvent
    if let eventID {
        guard let found = try store.events(limit: 5000).first(where: { $0.id == eventID }) else {
            FileHandle.standardError.write(Data("error: no event with ID \(eventID)\n".utf8))
            exit(1)
        }
        event = found
    } else {
        guard let newest = try store.recentEvents(limit: 1).first else {
            print("Quarantine database is empty.")
            return
        }
        event = newest
    }

    let when = event.timestamp.map { $0.formatted(timestampFormat) } ?? "unknown time"
    print("Event \(event.id)")
    print("  \(event.agentName ?? "?") — \(event.kind.label) — \(when)")
    print("  Searching for file (this walks Downloads/Desktop/Documents/Applications)…")

    let enrichment = await EventEnricher().enrich(event)
    switch enrichment.fileStatus {
    case .notFound:
        print("  File: not found (likely deleted — normal for older events)")
    case .found(let path):
        print("  File: \(path)")
        if let assessment = enrichment.assessment {
            print("  Gatekeeper: \(assessment.accepted ? "would allow" : "WOULD BLOCK")")
            for line in assessment.detail.split(separator: "\n") {
                print("    \(line)")
            }
        } else {
            print("  Gatekeeper: not an assessable type (only app/pkg/dmg)")
        }
        if let signature = enrichment.signature {
            switch signature.status {
            case .signed:
                print("  Signature: signed")
                for authority in signature.authorities { print("    \(authority)") }
            case .unsigned:
                print("  Signature: not code-signed")
            case .invalid:
                print("  Signature: INVALID — \(signature.problem ?? "unknown problem")")
            }
        }
    }
}

let arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.first else { printUsageAndExit() }

do {
    switch command {
    case "status":
        runStatus()
    case "quarantine":
        let limit = arguments.dropFirst().first.flatMap { Int($0) } ?? 20
        try runQuarantine(limit: limit)
    case "agents":
        try runAgents()
    case "xprotect-log":
        let window = arguments.dropFirst().first ?? "1h"
        try await runXProtectLog(window: window)
    case "activities":
        let window = arguments.dropFirst().first ?? "6h"
        try await runActivities(window: window)
    case "enrich":
        try await runEnrich(eventID: arguments.dropFirst().first)
    default:
        printUsageAndExit()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
