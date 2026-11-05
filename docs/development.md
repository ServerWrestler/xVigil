# Development notes

## Layout

- `Sources/xVigilCore/`: data layer that never modifies the security state
  it observes (quarantine DB, XProtect log parsing, system status, watchlist
  models/store/checker/fetcher; the store writes only xVigil's own config)
- `Sources/xVigilScan/`: on-demand scanning (`ScanEngine` protocol, ClamAV
  backend) and the ClamAV update flow (`ClamAVMaintenance`)
- `Sources/xVigil/`: menu bar app + dashboard (SwiftUI)
- `Sources/xvigil-cli/`: CLI harness for the data layer
- `Tests/`: unit tests against fixture data
- `scripts/make-app.sh <version>`: builds, signs (ad-hoc), and zips
  `dist/xVigil.app`

## CLI harness

```sh
swift run xVigil                    # menu bar app
swift test                          # unit tests

swift run xvigil-cli status         # Gatekeeper + XProtect versions
swift run xvigil-cli quarantine 20  # recent quarantine events
swift run xvigil-cli agents         # event counts by downloading app
swift run xvigil-cli xprotect-log 2h
swift run xvigil-cli activities 12h # log entries grouped into activities
swift run xvigil-cli enrich         # locate file + verdicts for newest event
swift run xvigil-cli engine         # ClamAV availability + signature age
swift run xvigil-cli scan ~/Downloads   # on-demand scan (report-only)
```

Debug-only harnesses run inside the real GUI process:

- `XVIGIL_SMOKE=1 .build/debug/xVigil`: headless self-check of the
  dashboard's data paths (one event, every pane).
- `XVIGIL_UITEST=1 .build/debug/xVigil`: opens the dashboard and selects a
  spread of real events in turn, logging how long each takes to resolve.
  Use this for anything the user sees: model-level checks pass happily while
  the view is broken (see the `.task(id:)` note below).
- `XVIGIL_UITEST=1 XVIGIL_UITEST_UPDATE=1 XVIGIL_FAKE_PREFIX=<dir>
  .build/debug/xVigil`: opens the Scan pane and runs the ClamAV update
  against a scripted fake Homebrew prefix (`<dir>/bin/brew`,
  `<dir>/bin/freshclam`, `<dir>/etc/clamav/freshclam.conf`), so the flow can
  be exercised and screenshotted without touching the real install.

## Implementation notes

- `LSQuarantineTimeStamp` is seconds since the Core Data reference date
  (2001-01-01); `Date(timeIntervalSinceReferenceDate:)` decodes it directly.
- On recent macOS versions the quarantine DB's URL and sender columns are
  usually NULL. Agent name, timestamp, and type are the reliable fields.
- Apple records type numbers beyond the documented 0-5 (GarageBand content
  downloads are type 7), so type filters must be data-driven.
- The quarantine DB stores no file path. The linkage goes the other way:
  quarantined files carry a `com.apple.quarantine` xattr
  (`flags;hex-timestamp;agent;event-UUID`) whose UUID keys into the DB.
- macOS prunes DB rows on its own schedule while files keep their xattrs, so
  DB→file correlation can fail in both directions. "File not found" is a
  normal outcome, not an error.
- Messages attachments can dominate the quarantine database (over 80% of
  one real Mac's events). They live in TCC-protected
  `~/Library/Messages/Attachments`; file search needs Full Disk Access to
  reach them, and reports honestly when it can't.
- Always invoke `/usr/bin/log` by full path: zsh has a `log` builtin that
  silently shadows it.
- GUI apps inherit launchd's minimal PATH, so the ClamAV update calls brew
  and freshclam by absolute path and sets `PATH` and the non-interactive
  Homebrew variables explicitly.
- Homebrew ships only `freshclam.conf.sample`; `freshclam` will not run until
  it is copied to `freshclam.conf`. An outdated ClamAV also cannot verify a
  current signature database (it fails with "Incorrect digital signature"),
  which is why the update flow upgrades ClamAV before running `freshclam`.
- `brew upgrade <formula>` exits 0 when the formula is already current, so a
  no-op upgrade is not treated as a failure.
- One logical XProtect scan run interleaves several processes, so activity
  clustering splits on time gaps only, never on process changes.
- Nothing blocks Swift Concurrency's fixed-width cooperative pool, because
  blocking it starves every task in the app. Subprocesses use readability and
  termination handlers (no thread is held while one runs), and filesystem
  walks and hashing run on dedicated GCD queues.
- SwiftUI: a bare `.task {}` placed *after* `.id(x)` sits outside the
  identity `.id` establishes, so it runs once and never re-runs when `x`
  changes. The quarantine detail pane needs `.task(id: event.id)`; without
  it, selecting a second event never starts its lookups and the pane spins
  forever. No model-level test catches this, so verify with `XVIGIL_UITEST`.

## Repo hygiene

Enable the secret-scanning pre-commit hook once per clone:

```sh
git config core.hooksPath .githooks
```

It blocks staged changes resembling keys, tokens, credentials, home paths,
or email addresses. Machine-specific patterns go in
`.git/info/personal-patterns` (never committed). Bypass a false positive
with `git commit --no-verify`.
