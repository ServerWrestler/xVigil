# 🛡️ xVigil

A macOS menu bar app that surfaces what XProtect and Gatekeeper are quietly doing:
quarantine events, protection status, and XProtect activity from the unified log.

## Status

Early prototype. Working so far:

- **Menu bar app** (`swift run xVigil`) — SwiftUI `MenuBarExtra` showing Gatekeeper
  status, XProtect definition/Remediator versions, and recent quarantine events.
  Clicking an event opens it in the dashboard.
- **Dashboard window** — `NavigationSplitView` with three sections: quarantine
  events (searchable, filterable by agent/type, keyset-paginated), XProtect
  activity (log entries clustered into scan runs), and protection status.
- **Quarantine layer** (`QuarantineStore`) — read-only SQLite access to
  `~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2`, with
  filtered queries and pagination.
- **Event enrichment** (`EventEnricher` / `QuarantineFileLocator`) — locates the
  on-disk file for an event by scanning common directories for a matching
  `com.apple.quarantine` xattr UUID, then reports today's Gatekeeper verdict
  (`spctl`) and code signature (`codesign`).
- **Log parsing** (`XProtectLogReader` / `XProtectLogParser`) — shells out
  to `/usr/bin/log show --style ndjson` with an XProtect/Gatekeeper predicate and
  parses entries into typed values with a rough detection/assessment/scan
  classification. Supports both relative windows and absolute time ranges (used
  to show log context around a quarantine event).
- **Activity grouping** (`XProtectActivityGrouper`) — clusters the raw entry
  stream by time gap into logical activities (a 12h window collapses from ~28k
  entries to ~15 activities), titled by the dominant process.

## Install (beta)

Grab `xVigil-x.y.z.zip` from [Releases](https://github.com/ServerWrestler/xVigil/releases),
unzip, and drag `xVigil.app` to Applications. The beta is ad-hoc signed, so on
first launch macOS will warn — right-click the app and choose **Open** (yes,
the Gatekeeper-visibility app makes you talk to Gatekeeper; consider it a
product demo). Or build it yourself:

```sh
scripts/make-app.sh 0.1.0   # produces dist/xVigil.app and a zip
```

## Setup

After cloning, enable the secret-scanning pre-commit hook (once per clone):

```sh
git config core.hooksPath .githooks
```

The hook blocks staged changes that look like keys, tokens, hardcoded
credentials, absolute home paths, or email addresses. Machine-specific
patterns (your own username, addresses, …) go in `.git/info/personal-patterns`
(one extended regex per line) — that file lives under `.git/` and is never
committed. Bypass a false positive with `git commit --no-verify`.

## Usage

```sh
swift run xVigil                    # menu bar app
swift test                          # unit tests

# CLI harness for the data layer:
swift run xvigil-cli status         # Gatekeeper + XProtect versions
swift run xvigil-cli quarantine 20  # recent quarantine events
swift run xvigil-cli agents         # event counts by downloading app
swift run xvigil-cli xprotect-log 2h
swift run xvigil-cli activities 12h # log entries grouped into activities
swift run xvigil-cli enrich         # locate file + verdicts for newest event
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
- The quarantine DB stores no file path. The linkage goes the other way:
  quarantined files carry a `com.apple.quarantine` xattr
  (`flags;hex-timestamp;agent;event-UUID`) whose UUID keys into the DB.
- macOS purges old DB rows while files keep their xattrs, so DB→file
  correlation only succeeds for recent events — "file not found" is a normal
  outcome, not an error.
- Always invoke `/usr/bin/log` by full path: zsh has a `log` builtin that
  silently shadows it.
- One logical scan run interleaves several processes (XProtect,
  XProtectPluginService, …), so activity clustering splits on time gaps only,
  never on process changes.

## Next ideas

- `log stream` for live tailing instead of polled `log show`
- Notifications on new quarantine events (poll DB mtime)
- Drop-a-file-to-verify: `spctl`/`codesign` verdict for any file, not just
  quarantine events
- Login item support
- Pluggable on-demand scanning (spec below)

### Spec: pluggable on-demand scanning (user-defined engine)

Add active, report-only scanning of user-specified paths (e.g. `/usr/local`,
Homebrew Cellar) via a pluggable engine backend. Fills the gap that XProtect
never proactively scans these locations. First backend: ClamAV.

**Architecture** — keep `xVigilCore` pure-read; isolate scanning behind a
protocol:

```swift
protocol ScanEngine {
    var id: String { get }            // "clamav"
    var displayName: String { get }
    func availability() async -> EngineAvailability   // installed? daemon up? db age
    func scan(paths: [URL], options: ScanOptions) -> AsyncStream<ScanEvent>
}
```

`ScanEvent`: `.fileScanned(URL)`, `.threatFound(path:signature:)`,
`.progress(...)`, `.finished(summary:)`. UI stays engine-agnostic; mirrors the
existing streamed-typed-event pattern. Future backends (rkhunter, YARA) plug
in without touching views.

**ClamAV backend requirements:**

- Prefer `clamdscan` (daemon) over `clamscan` — avoids ~200MB DB reload per
  run. Detect which is available; fall back gracefully.
- Detect, don't bundle. Resolve via `which clamdscan` / `brew --prefix`.
  Bundling drags in GPL + a signature-update pipeline. Detection keeps
  licensing clean and the "user-defined engine" framing honest.
- Use `clamdscan --fdpass` to avoid daemon file-permission failures on paths
  clamd's user can't read.
- Surface signature DB age prominently in `availability()` and warn in UI if
  stale (`freshclam` neglect → false confidence). On-brand: this app exists
  to distrust silent security.
- Never auto-quarantine or delete. Report only; offer "reveal in Finder."
  Silent action would betray the observability ethos.

**Distribution note:** shelling out to `clamdscan` + reading arbitrary paths
is incompatible with App Sandbox. Confirms the Developer-ID-signed,
unsandboxed path (already required for `spctl`/`codesign`/log access).

**Scope guard:** ship on-demand only. Scheduled scans are a reasonable
follow-up. File-on-write monitoring is explicitly out of scope — it requires
an Endpoint Security System Extension and the restricted
`com.apple.developer.endpoint-security.client` entitlement (Apple approval).
Do not let on-demand scanning silently grow into that without a deliberate
decision.

**First slice:** `ScanEngine` protocol + `ClamAVEngine` (availability
detection + `clamdscan --fdpass` streaming) + a new dashboard section beside
XProtect activity showing streamed results and DB-age warning.
