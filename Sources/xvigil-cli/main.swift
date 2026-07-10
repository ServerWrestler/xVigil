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

func runXProtectLog(window: String) throws {
    let entries = try XProtectLogReader().entries(last: window)
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
        try runXProtectLog(window: window)
    default:
        printUsageAndExit()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
