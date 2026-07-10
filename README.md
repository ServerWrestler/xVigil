# xVigil

A macOS menu bar app that surfaces what XProtect and Gatekeeper are quietly doing:
quarantine events, protection status, and XProtect activity from the unified log.

## Status

Early prototype. Working so far:

- **Menu bar app** (`swift run xVigil`) — SwiftUI `MenuBarExtra` showing Gatekeeper
  status, XProtect definition/Remediator versions, and recent quarantine events.
- **Quarantine layer** (`QuarantineStore`) — read-only SQLite access to
  `~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2`.
- **Log parsing prototype** (`XProtectLogReader` / `XProtectLogParser`) — shells out
  to `/usr/bin/log show --style ndjson` with an XProtect/Gatekeeper predicate and
  parses entries into typed values with a rough detection/assessment/scan classification.

## Usage

```sh
swift run xVigil                    # menu bar app
swift test                          # unit tests

# CLI harness for the data layer:
swift run xvigil-cli status         # Gatekeeper + XProtect versions
swift run xvigil-cli quarantine 20  # recent quarantine events
swift run xvigil-cli agents         # event counts by downloading app
swift run xvigil-cli xprotect-log 2h
```

## Layout

- `Sources/xVigilCore/` — data layer (quarantine DB, log parsing, system status)
- `Sources/xVigil/` — menu bar app
- `Sources/xvigil-cli/` — CLI harness for prototyping
- `Tests/xVigilCoreTests/` — unit tests against fixture data

## Implementation notes

- `LSQuarantineTimeStamp` is seconds since the Core Data reference date
  (2001-01-01); `Date(timeIntervalSinceReferenceDate:)` decodes it directly.
- On recent macOS versions the quarantine DB's URL columns are often NULL —
  agent name, timestamp, and type are the reliable fields.
- Always invoke `/usr/bin/log` by full path: zsh has a `log` builtin that
  silently shadows it.
- Much of the XProtect log volume is XPC scheduling chatter; filtering that
  down to meaningful scan/detection events is the next parsing task.

## Next ideas

- Filter/collapse XPC noise in the log view; surface only scans and detections
- `log stream` for live tailing instead of polled `log show`
- Notifications on new quarantine events (poll DB mtime)
- `spctl --assess` wrapper for manual file verification
- Proper `.app` bundle + login item
