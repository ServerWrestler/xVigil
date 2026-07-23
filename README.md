# 🛡️ xVigil

**xVigil is a macOS security product.** Apple ships real protection with
every Mac — XProtect malware scanning, Gatekeeper, quarantine — but it all
works in silence: scans you never see, verdicts you never read, records
buried in databases you'd never open. xVigil lives in your menu bar and puts
that machinery on screen — loudly, when something is found.

**What it does:**

- **Watches** — sweeps XProtect's activity in the background. A detection
  turns the menu bar shield red, banners the popover, and files into a
  Detections pane. No detections means a quiet shield, verifiably — not
  silence you have to trust.
- **Explains** — every quarantine event on your Mac: what was downloaded, by
  which app, from where. Drill into an event to locate the file on disk, get
  Gatekeeper's verdict on it today, inspect its code-signature chain, and see
  the system's own log activity around the moment it arrived.
- **Scans** — on-demand and scheduled ClamAV scans of the places Apple's
  tools never proactively check (Homebrew prefixes, Downloads). Report-only
  by design: xVigil tells you what it found and where; it never quarantines
  or deletes anything.

## Features

- **Menu bar app** (`swift run xVigil`) — SwiftUI `MenuBarExtra` showing Gatekeeper
  status, XProtect definition/Remediator versions, and recent quarantine events.
  Clicking an event opens it in the dashboard.
- **Loud detections** — a background monitor sweeps XProtect logs; any finding
  turns the menu bar icon into a red warning shield, banners the popover, and
  lands in a Detections dashboard section.
- **App behavior** — a shield Dock icon appears while the dashboard is open;
  optional start-at-login toggle in the Status pane (installed .app only).
- **Update check** — optionally checks GitHub Releases for a newer version on
  a daily, weekly, or monthly cadence (one anonymous request; notify-and-link
  only, never auto-installed). Configurable in the Status pane.
- **On-demand + scheduled scanning** — pluggable `ScanEngine` with a ClamAV
  backend: detects a Homebrew install, prefers the daemon, warns on stale
  signatures, streams results live, and can run automatically on a daily or
  weekly schedule. Report-only — never quarantines or deletes.
- **Dashboard window** — `NavigationSplitView` with five sections: detections,
  quarantine events (searchable, filterable by agent/type, paginated),
  XProtect activity (log entries clustered into scan runs), on-demand scan,
  and protection status.
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

## Install

Grab `xVigil-x.y.z.zip` from [Releases](https://github.com/ServerWrestler/xVigil/releases),
unzip, and drag `xVigil.app` to Applications. Releases are ad-hoc signed, so
on first launch macOS will warn — right-click the app and choose **Open**
(yes, the Gatekeeper-visibility app makes you talk to Gatekeeper; consider it
a product demo). Or build it yourself:

```sh
scripts/make-app.sh 1.0.0   # produces dist/xVigil.app and a zip
```

Requires macOS 15+. ClamAV (`brew install clamav`) is optional and only
needed for on-demand scanning.

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
swift run xvigil-cli engine         # ClamAV availability + signature age
swift run xvigil-cli scan ~/Downloads   # on-demand scan (report-only)
```

## Layout

- `Sources/xVigilCore/` — pure-read data layer (quarantine DB, log parsing,
  system status)
- `Sources/xVigilScan/` — on-demand scanning (`ScanEngine` protocol, ClamAV
  backend)
- `Sources/xVigil/` — menu bar app + dashboard
- `Sources/xvigil-cli/` — CLI harness for prototyping
- `Tests/` — unit tests against fixture data (core and scan)

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
- Notifications on new quarantine events and new detections
- Drop-a-file-to-verify: `spctl`/`codesign` verdict for any file, not just
  quarantine events
- More scan engines behind `ScanEngine` (YARA, rkhunter); file-on-write
  monitoring stays out of scope (needs an Endpoint Security entitlement)
