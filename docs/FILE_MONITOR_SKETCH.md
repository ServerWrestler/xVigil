# File Monitor Feature — Implementation Sketch (rev 2)

> **For the implementing model:** This is a spec for a new feature in xVigil,
> a Swift/SwiftUI macOS menu-bar security app. The project uses Swift 6.0,
> targets macOS 15+, and follows a 3-module SPM structure. All new types
> must be `Codable + Sendable` (project-wide convention). Read the existing
> code patterns referenced below and match them exactly. Do not edit docs
> without asking the user. Build after every change.

## 1. What we're building

A **File Monitor** — a unified file watchlist that combines four capabilities
into a single entry type:

1. **Existence check** — does a file/path exist? (always evaluated)
2. **Integrity monitoring** — has a file changed since last check? (SHA-256
   hash compare, opt-in per entry)
3. **IOC hunting** — glob/recursive directory resolution to find files
   matching a pattern (opt-in via `recursive` flag + glob target)
4. **Content inspection** — regex search inside readable text files for
   keywords or indicators (opt-in via `contentPatterns` array)

Each watchlist entry can combine any or all of these. One entry could watch
`~/Library/LaunchAgents/` recursively, track integrity on everything there,
AND scan plist contents for a suspicious domain — all in one check pass.

Entries come from two sources:
- **Local** — user creates and edits them in the dashboard
- **Remote** — fetched as JSON from a configured URL (like an IOC feed)

Remote entries are replaced on fetch; local entries are preserved. Persistent
check state (integrity baselines, last results) lives in a **separate state
file** keyed by entry ID, so a remote refresh never destroys baselines
(see §3a, `WatchlistCheckState`).

### Alert semantics (important — read this)

Not every finding is an alarm. Whether a check result raises a red-shield
alert is governed by the entry's `alertConditions`:

```swift
public enum AlertCondition: String, Codable, Sendable, CaseIterable {
    case onPresence   // alert if a matching file EXISTS (IOC-style)
    case onAbsence    // alert if the target is MISSING (sentinel file)
    case onChange     // alert if a tracked hash CHANGED (integrity)
    case onMatch      // alert if a content regex MATCHED
}
```

**Defaulting rule** (applies when the user/feed omits `alertConditions`, and
drives what the "Add entry" UI pre-selects):

- Plain existence entry (no integrity, no patterns) → `[.onPresence]`.
  **A plain existence entry alerts when the file is found.** This is the
  IOC-hunting default: you list a file because finding it is bad news.
- `trackIntegrity == true` → add `.onChange`
- `contentPatterns` non-empty → add `.onMatch`
- `.onAbsence` is never a default; the user opts in explicitly.

Every check still *records* all facts (exists, hash state, matches) in the
findings shown in the pane — `alertConditions` only controls which findings
are promoted to `Finding`s in `DetectionMonitor` (red menu-bar shield).

## 2. Architecture overview

The project has three SPM modules:

```
xVigilCore   — pure data models, stores, parsers (no UI, no AppKit)
xVigilScan   — on-demand scanning (ScanEngine protocol + ClamAVEngine)
xVigil       — the menu-bar app (SwiftUI views + controllers)
```

All new data models and pure logic go in **xVigilCore**. The app-scope
controller goes in **xVigil**. The dashboard pane goes in
**xVigil/Dashboard/**.

Key existing patterns to mirror:

- `QuarantineStore` (xVigilCore) — a `Sendable` struct that does I/O,
  instantiated where needed. The watchlist store follows this pattern but
  uses JSON files instead of SQLite.
- `ScanController` (xVigil) — `@MainActor @Observable`, app-scope, owns a
  `Task`-based schedule loop, persists scalar settings to `UserDefaults`.
- `ScanEngine` protocol (xVigilScan) — streams results via
  `AsyncStream<ScanEvent>`. `WatchlistChecker` mirrors this with
  `AsyncStream<WatchlistEvent>`.
- `DashboardModel.Section` enum — `CaseIterable`, drives the sidebar. Add
  a new case; the sidebar auto-picks it up.
- `Finding` (xVigilCore) — the app-wide detection type with a `Source`
  enum. Add a `.fileMonitor` source case so watchlist alerts appear
  alongside XProtect and scan detections.
- `DetectionMonitor` (xVigil) — the app-wide findings surface. It currently
  holds `xprotectFindings` + `scanFindings`; it gains a third array (§4).

## 3. Files to create

### 3a. xVigilCore — Data models and logic

#### `Sources/xVigilCore/Watchlist/WatchlistEntry.swift` (NEW)

The core data model. **Pure configuration — no mutable check state.**
`Codable, Sendable, Identifiable, Hashable`.

```swift
public struct WatchlistEntry: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var target: String            // absolute path, directory, or glob; MAY start with "~"
    public var label: String             // human-friendly name
    public var notes: String?
    public var source: Source
    public var recursive: Bool           // for directory/glob targets
    public var trackIntegrity: Bool      // hash + compare on each check
    public var contentPatterns: [String] // regex strings; empty = no content scan
    public var alertConditions: [AlertCondition]  // see §1; decode-default per rules above

    public enum Source: Codable, Sendable, Hashable {
        case local
        case remote(url: String)
    }
}
```

**⚠️ `Source` must NOT declare a raw type.** An enum with associated values
cannot have a `String` raw value — `enum Source: String { case remote(url:) }`
is a compile error. Declare it exactly as above. Swift auto-synthesizes
`Codable` for associated-value enums, but the synthesized JSON is awkward for
a hand-editable file; implement custom `Codable` producing:

```json
{ "type": "local" }
{ "type": "remote", "url": "https://example.com/watchlist.json" }
```

Use a custom `init(from:)` for the entry (or default values) so that a JSON
entry omitting `alertConditions` gets the defaulting rule from §1 rather
than failing to decode. Same for optional fields a hand-edited or remote
file might omit (`notes`, `recursive` → false, etc.).

#### `Sources/xVigilCore/Watchlist/WatchlistCheckState.swift` (NEW)

Mutable per-entry check state, kept **separate from the entry config** so
that (a) remote refreshes never clobber integrity baselines and (b)
`WatchlistEntry` stays value-stable for `Hashable`/list identity.
`Codable, Sendable`.

```swift
public struct WatchlistCheckState: Codable, Sendable {
    public var lastChecked: Date?
    /// Integrity baselines: resolved absolute path → SHA-256 hex digest.
    /// A dictionary, NOT a single hash — one entry (glob/recursive dir)
    /// can resolve to many files, each needing its own baseline.
    public var baselineHashes: [String: String]
    public var findings: [WatchlistFinding]
}
```

Persisted as `[UUID: WatchlistCheckState]` (see `WatchlistStore`). State for
entry IDs that no longer exist in the watchlist is pruned on save.

#### `Sources/xVigilCore/Watchlist/WatchlistFinding.swift` (NEW)

Result of checking a single resolved file path. `Codable, Sendable,
Identifiable, Hashable`.

```swift
public struct WatchlistFinding: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let path: String
    public let exists: Bool
    public let hashChanged: Bool?        // nil if integrity not tracked or first baseline
    public let matchedPatterns: [String] // which regexes hit; empty = none
    public let error: String?            // per-file error (permission, too large, bad regex…)

    /// True when this finding satisfies any of the entry's alertConditions.
    /// Computed by the checker and used to build DetectionMonitor Findings.
    public let isAlert: Bool
}
```

#### `Sources/xVigilCore/Watchlist/WatchlistStore.swift` (NEW)

Local persistence. `Sendable` struct, mirrors `QuarantineStore`'s structural
pattern (init takes a base directory URL, defaulting to the real location,
so tests can point it at a temp dir).

```
~/Library/Application Support/xVigil/watchlist.json        — entries (config)
~/Library/Application Support/xVigil/watchlist-state.json  — check state by entry ID
```

Formats: `{ "version": 1, "entries": [WatchlistEntry…] }` and
`{ "version": 1, "state": { "<uuid>": WatchlistCheckState, … } }`.

Methods:
- `loadEntries() throws -> [WatchlistEntry]` — missing file ⇒ `[]`, not an error
- `saveEntries(_:) throws`
- `loadState() throws -> [UUID: WatchlistCheckState]` — missing file ⇒ `[:]`
- `saveState(_:) throws` — prunes IDs not present in the current entry list
  (pass the entries in, or expose `prune(state:keeping:)`)
- `merge(remote: [WatchlistEntry], into local: [WatchlistEntry]) -> [WatchlistEntry]`
  — result = all `.local` entries from `local`, plus the fetched `remote`
  set (which wholesale replaces previous `.remote` entries). Dedup by `id`;
  on collision the local entry wins. **Check state is untouched by merge**
  — because state lives in the separate state file keyed by ID, a remote
  entry that persists across fetches (same `id`) automatically keeps its
  integrity baselines. That is the point of the state/config split.

#### `Sources/xVigilCore/Watchlist/WatchlistFetcher.swift` (NEW)

Remote fetch. `Sendable` struct. **Treat the feed as untrusted input** —
this is a security app; a hostile or sloppy feed must not be able to hang
or mislead it.

- `fetch(from url: URL) async throws -> [WatchlistEntry]` — `URLSession`,
  30s timeout, decodes the same JSON format the store uses.
- **HTTPS only.** Reject non-`https` schemes with a descriptive error.
- **Caps, enforced on decode** (violations throw with a message the UI
  surfaces): max **200 entries** per feed, max **32 contentPatterns** per
  entry, max **512 characters** per pattern.
- Do NOT compile or execute regexes here — validation happens in the
  checker (which also guards local entries). The fetcher only enforces
  size/shape.

No auth in v1. If auth is needed later, a bearer token from Keychain can be
added — not in this implementation.

#### `Sources/xVigilCore/Watchlist/WatchlistChecker.swift` (NEW)

The check engine. `Sendable` struct. Resolves targets, checks existence,
hashes for integrity, regex-scans content. Pure data work, no UI dependency.
Testable from `xVigilCoreTests`, exercisable from `xvigil-cli`.

```swift
public struct WatchlistChecker: Sendable {
    public init() {}

    /// Streams check events as they complete. One pass over all entries.
    /// `state` supplies prior baselines; the caller persists the updated
    /// state carried on `.completed` events.
    public func check(
        entries: [WatchlistEntry],
        state: [UUID: WatchlistCheckState]
    ) -> AsyncStream<WatchlistEvent>
}

public enum WatchlistEvent: Sendable {
    case checking(entry: WatchlistEntry)
    case found(WatchlistFinding, for: WatchlistEntry)
    case completed(entry: WatchlistEntry, state: WatchlistCheckState)
    case failed(entry: WatchlistEntry, error: String)
    case finished  // all entries done
}
```

Check logic per entry, in order:

1. **Expand tilde.** `target` may start with `~` (the JSON examples do, and
   users will type it). `FileManager` does **not** expand tildes — apply
   `(target as NSString).expandingTildeInPath` before anything else, or the
   entry silently matches nothing.
2. **Validate regexes up front.** Compile every `contentPattern` with
   `NSRegularExpression` once per entry (cache the compiled set). A pattern
   that fails to compile is skipped and recorded as a finding `error`
   (`"invalid pattern: …"`); it must not abort the entry or the pass.
3. **Resolve target.** If the expanded target contains glob characters
   (`*`, `?`, `[`), enumerate the glob's parent directory with
   `FileManager.enumerator` (deep if `recursive`, shallow otherwise) and
   filter by the pattern (`fnmatch` or a translated regex). Otherwise treat
   it as a literal path; if it's a directory and `recursive`, enumerate it.
4. **Cap results.** Stop after **500** resolved files per entry; if hit,
   append a finding with `error: "truncated — refine pattern"`.
5. **For each resolved file:**
   - Existence: `FileManager.fileExists`.
   - If `trackIntegrity`: SHA-256 via `CryptoKit` (`import CryptoKit`,
     `SHA256.hash(data:)` streaming over file chunks). Compare against
     `state.baselineHashes[path]`. `hashChanged` is `true`/`false` on
     compare, `nil` when there was no prior baseline (first sight is not a
     change). Write the current hash into the updated state.
   - If `contentPatterns` non-empty:
     - Skip files > **1 MB** (`error: "file too large, skipped content scan"`).
     - **Binary sniff:** read the first 8 KB; if it contains a NUL byte or
       is not valid UTF-8, skip content scanning for that file
       (`error: nil`, just no content scan — record nothing matched).
       Regex-scanning Mach-O bytes as text is noise.
     - **Time budget:** at most **2 seconds** of regex matching per file
       (wall clock, checked between patterns). `NSRegularExpression` can
       catastrophically backtrack on pathological patterns (ReDoS) — a bad
       feed pattern must not hang the pass. On budget exhaustion record
       `error: "content scan timed out"` and move on.
     - Record matched pattern strings in `matchedPatterns`.
   - Compute `isAlert` from the entry's `alertConditions`:
     `.onPresence` && exists → alert; `.onAbsence` && !exists (literal,
     non-glob targets only) → alert; `.onChange` && hashChanged == true →
     alert; `.onMatch` && !matchedPatterns.isEmpty → alert.
6. Emit `.found` per file, then `.completed` with the entry's fully updated
   `WatchlistCheckState` (`lastChecked = now`, new baselines, findings).

The checker's stream body runs its blocking work off the cooperative pool
(wrap the walk in the same `Task.detached` / GCD style the rest of the
codebase uses). Report-only contract, same as `ScanEngine`: **never modify,
quarantine, or delete anything.**

### 3b. xVigil — App-scope controller

#### `Sources/xVigil/WatchlistController.swift` (NEW)

`@MainActor @Observable`, app-scope. Mirrors `ScanController` in structure.
Instantiated in `XVigilApp.init()` alongside `ScanController`.

State:
- `private(set) var entries: [WatchlistEntry]`
- `private(set) var checkState: [UUID: WatchlistCheckState]`
- `private(set) var isChecking = false`
- `private(set) var lastCheck: Date?`
- `private(set) var checkError: String?`
- `private(set) var checkProgress: (checked: Int, total: Int)?`
- `private(set) var lastFetch: Date?` / `fetchError: String?`
- `var remoteURL: String` — persisted to UserDefaults
- `var autoRefresh: Bool` — persisted to UserDefaults
- `var refreshFrequency: Frequency` (`.hourly` / `.daily`) — persisted

Methods:
- `start()` — idempotent; schedule loop (`Task` + `Task.sleep`, 15-min tick,
  same shape as `ScanController.start()`), triggering `fetchRemote()` and/or
  `checkNow()` when due.
- `loadLocal()` — `store.loadEntries()` + `store.loadState()`
- `fetchRemote() async` — fetch → `store.merge` → `saveEntries` → update
  `entries`. Fetch failures set `fetchError`; they never touch entries.
- `checkNow()` — runs `checker.check(entries:state:)`, consumes the stream,
  updates `checkState` per `.completed`, saves state at the end, updates
  `checkProgress` live.
- `addEntry(_:)`, `removeEntry(_:)`, `updateEntry(_:)` — local CRUD;
  saves entries (and prunes state on remove).

On check completion, findings with `isAlert == true` become
`Finding(source: .fileMonitor, date: Date(), title: <why>, detail: <path>,
path: <path>)` pushed via `monitor.setFileMonitorFindings(_:)` (new method,
§4). Clear with `setFileMonitorFindings([])` at the start of each pass,
mirroring `ScanController`'s `monitor.setScanFindings([])`.

### 3c. xVigil — Dashboard pane

#### `Sources/xVigil/Dashboard/FileMonitorPaneView.swift` (NEW)

SwiftUI. Same skeleton as `ScanPaneView` / `StatusPaneView`:
`Form { Section(…) }.formStyle(.grouped)`.

**Section 1: "Entries"**
- Rows: label, target (monospaced, middle-truncated), source badge
  ("local" / "remote"), alert-condition summary, last-check status icon
- Add button → sheet: target, label, recursive toggle, integrity toggle,
  content patterns (one per line), alert-condition checkboxes pre-selected
  per the §1 defaulting rule
- Minus button removes local entries; remote entries are read-only
  (badge shows the feed hostname)

**Section 2: "Remote source"**
- `TextField` for the feed URL (validate https on commit)
- "Fetch now" button + spinner + last-fetched timestamp + fetch error
- Auto-refresh `Toggle`, frequency `Picker`

**Section 3: "Check"**
- "Check now" button, progress ("Checking 3/12…" + `ProgressView`),
  last-checked timestamp, check error

**Section 4: "Results"** (only when findings exist)
- Alert findings first (red `exclamationmark.shield.fill`, like
  `ScanPaneView` threat rows), then informational findings
- Each row: path (monospaced, truncated middle), reason ("found",
  "hash changed", "matched: <pattern>", or the per-file error), and a
  "Reveal" button (`NSWorkspace.shared.activateFileViewerSelecting`)

### 3d. Tests (all REQUIRED, in `Tests/xVigilCoreTests/`)

#### `WatchlistCheckerTests.swift` (NEW)
- Literal path exists / not-exists; tilde expansion (`~/…` resolves)
- Glob resolution (`*.plist` in a temp dir); recursive vs shallow
- Integrity: first sight ⇒ `hashChanged == nil`; content change ⇒ `true`;
  unchanged ⇒ `false`; per-path baselines for multi-file entries
- Content: regex match / no match; invalid regex recorded as error, pass
  continues; > 1 MB skipped; binary file (NUL bytes) skipped
- Alert conditions: onPresence fires on existing file; onAbsence fires on
  missing literal target; onChange/onMatch gating
- 500-file cap truncates with error finding

#### `WatchlistStoreTests.swift` (NEW)
- Entries + state round-trip; missing files ⇒ empty, no throw
- Merge: fetched set replaces `.remote`, preserves `.local`; id collision →
  local wins; **state survives a merge** (baseline present before fetch is
  present after)
- State pruning drops IDs absent from the entry list
- Decode: entry JSON omitting `alertConditions` gets the documented defaults

#### `WatchlistFetcherTests.swift` (NEW)
- Decode valid JSON; reject malformed JSON
- Reject `http://` URL; reject > 200 entries; reject oversized patterns
- Timeout handling (`URLProtocol` mock)

## 4. Files to modify

### `Sources/xVigilCore/Finding.swift` (MODIFY)

```swift
public enum Source: String, Sendable {
    case xprotect
    case scan
    case fileMonitor    // NEW

    public var label: String {
        switch self {
        case .xprotect: "XProtect"
        case .scan: "On-demand scan"
        case .fileMonitor: "File Monitor"   // NEW
        }
    }
}
```

### `Sources/xVigil/DetectionMonitor.swift` (MODIFY)

`DetectionMonitor` currently aggregates exactly two sources. Add the third:

```swift
private(set) var fileMonitorFindings: [Finding] = []   // NEW

var findings: [Finding] {   // MODIFY: include the new array
    (scanFindings + fileMonitorFindings + xprotectFindings).sorted {
        ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
    }
}

var count: Int {            // MODIFY
    xprotectFindings.count + scanFindings.count + fileMonitorFindings.count
}

func setFileMonitorFindings(_ findings: [Finding]) {   // NEW
    fileMonitorFindings = findings
}
```

### `Sources/xVigil/DashboardModel.swift` (MODIFY)

1. Add the section case:
   ```swift
   enum Section: String, Hashable, CaseIterable {
       case detections = "Detections"
       case quarantine = "Quarantine Events"
       case activity = "XProtect Activity"
       case scan = "On-Demand Scan"
       case fileMonitor = "File Monitor"     // NEW
       case status = "Protection Status"
   }
   ```
2. Store the controller so the pane reaches it via `model.watchlist`
   (mirrors `model.scanner`):
   ```swift
   let watchlist: WatchlistController   // NEW

   init(monitor: DetectionMonitor, scanner: ScanController,
        watchlist: WatchlistController) {   // MODIFY signature
       …
       self.watchlist = watchlist
       …
   }
   ```

### `Sources/xVigil/Dashboard/DashboardView.swift` (MODIFY)

1. Content-pane switch: `case .fileMonitor: FileMonitorPaneView(model: model)`
2. Detail-pane switch: `case .fileMonitor: placeholder("File monitor")`
   (results are inline in the pane, same as `.scan` / `.status`)
3. `icon(for:)`: `case .fileMonitor: "eye.circle"`

### `Sources/xVigil/XVigilApp.swift` (MODIFY)

```swift
@State private var watchlist: WatchlistController   // NEW

init() {
    let monitor = DetectionMonitor()
    let scanner = ScanController(monitor: monitor)
    let watchlist = WatchlistController(monitor: monitor)          // NEW
    _monitor = State(initialValue: monitor)
    _scanner = State(initialValue: scanner)
    _watchlist = State(initialValue: watchlist)                    // NEW
    _dashboard = State(initialValue: DashboardModel(
        monitor: monitor, scanner: scanner, watchlist: watchlist)) // MODIFY
}
```

**Note:** the schedule loops start in `MenuBarLabel.onAppear`, and
`MenuBarLabel` is a separate private struct — it must gain a
`let watchlist: WatchlistController` property AND the `MenuBarExtra` label
call site must pass it:

```swift
} label: {
    MenuBarLabel(monitor: monitor, scanner: scanner,
                 watchlist: watchlist, updates: updates)   // MODIFY
}

// in MenuBarLabel:
.onAppear {
    monitor.start()
    scanner.start()
    watchlist.start()   // NEW
    updates.start()
}
```

### `Sources/xVigil/MenuBarView.swift` (MODIFY — optional)

Optional for v1: a file-monitor hits banner in the popover, following the
`detectionsBanner` pattern; clicking sets `dashboard.section = .fileMonitor`
and opens the dashboard window. (Alert findings already surface via
`DetectionMonitor`, so the existing detections banner covers the loud path;
this adds source-specific navigation only.)

## 5. File summary

### New files (10)

| File | Module | Purpose |
|---|---|---|
| `Sources/xVigilCore/Watchlist/WatchlistEntry.swift` | xVigilCore | Entry config model + Source + AlertCondition |
| `Sources/xVigilCore/Watchlist/WatchlistCheckState.swift` | xVigilCore | Per-entry mutable state (baselines, findings) |
| `Sources/xVigilCore/Watchlist/WatchlistFinding.swift` | xVigilCore | Per-file result model |
| `Sources/xVigilCore/Watchlist/WatchlistStore.swift` | xVigilCore | JSON persistence (entries + state) + merge |
| `Sources/xVigilCore/Watchlist/WatchlistFetcher.swift` | xVigilCore | Hardened remote JSON fetch |
| `Sources/xVigilCore/Watchlist/WatchlistChecker.swift` | xVigilCore | Check engine (resolve, hash, regex) + events |
| `Sources/xVigil/WatchlistController.swift` | xVigil | App-scope state + schedule loop |
| `Sources/xVigil/Dashboard/FileMonitorPaneView.swift` | xVigil | Dashboard pane UI |
| `Tests/xVigilCoreTests/WatchlistCheckerTests.swift` | tests | Check engine tests |
| `Tests/xVigilCoreTests/WatchlistStoreTests.swift` | tests | Store/merge/state tests |

Plus `Tests/xVigilCoreTests/WatchlistFetcherTests.swift` (required, §3d).

### Modified files (6)

| File | Changes |
|---|---|
| `Sources/xVigilCore/Finding.swift` | Add `.fileMonitor` to `Source` |
| `Sources/xVigil/DetectionMonitor.swift` | Add `fileMonitorFindings` array, setter, include in `findings`/`count` |
| `Sources/xVigil/DashboardModel.swift` | Add `.fileMonitor` section; add `watchlist` property + init param |
| `Sources/xVigil/Dashboard/DashboardView.swift` | Switch cases + icon |
| `Sources/xVigil/XVigilApp.swift` | Instantiate controller; pass to `DashboardModel` AND `MenuBarLabel`; start loop |
| `Sources/xVigil/MenuBarView.swift` | (Optional) file-monitor banner |

## 6. Design constraints and guardrails

- **No new SPM dependencies.** `CryptoKit` and `NSRegularExpression` ship
  with the platform.
- **All new types `Codable + Sendable`.** Hard project convention.
- **Never block the main thread.** File I/O, hashing, regex all run off the
  cooperative pool (`Task.detached` / GCD), as `QuarantineStore` usage and
  `SystemStatus.load()` already model.
- **Stream results live** via `AsyncStream<WatchlistEvent>`, mirroring
  `ScanEngine.scan(paths:)`.
- **Report-only.** Never modify, quarantine, or delete files.
- **Untrusted-feed hardening** (§3a fetcher + checker): HTTPS-only; entry/
  pattern/length caps; compile-validate regexes and skip bad ones; 2s per-
  file content-scan budget; binary sniff before content scan.
- **Caps:** 500 resolved files per entry; 1 MB content-scan size limit.
- **Tilde expansion is mandatory** before any filesystem access.
- **Config/state separation:** entries (config) and check state (baselines/
  findings) are separate files; merge touches only config, so remote
  refreshes preserve integrity baselines by construction.
- **Alert gating:** only findings satisfying `alertConditions` reach
  `DetectionMonitor`. Plain existence entries default to alert-on-found.
- **Build after every change** (`swift build`; release packaging via
  `make-app.sh`). Run `swift test` after core pieces land.

## 7. Suggested implementation order

1. `WatchlistEntry` + `AlertCondition` + `WatchlistFinding` +
   `WatchlistCheckState` (models, custom Codable, defaulting rules)
2. `WatchlistStore` (persistence + merge + prune)
3. `WatchlistChecker` (the meatiest piece)
4. `WatchlistCheckerTests` + `WatchlistStoreTests` — run `swift test`
5. `WatchlistFetcher` + `WatchlistFetcherTests`
6. `Finding.swift` + `DetectionMonitor.swift` (small, unblock the controller)
7. `WatchlistController`
8. `FileMonitorPaneView`
9. `DashboardModel` + `DashboardView` + `XVigilApp` wiring
10. `MenuBarView` banner (optional)
11. Full build + test + manual smoke of the pane

## 8. JSON format reference

### watchlist.json (local file; remote feeds serve the same shape)

```json
{
  "version": 1,
  "entries": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "target": "~/Library/LaunchAgents/*.plist",
      "label": "Launch Agents",
      "notes": "Watch for suspicious persistence",
      "source": { "type": "local" },
      "recursive": false,
      "trackIntegrity": true,
      "contentPatterns": ["evil\\.com", "exfil\\.(net|io)"],
      "alertConditions": ["onChange", "onMatch"]
    },
    {
      "id": "660f9500-f30c-52e5-b827-557766551111",
      "target": "/Library/LaunchDaemons/com.malware.helper.plist",
      "label": "Known-bad persistence plist",
      "source": { "type": "remote", "url": "https://example.com/watchlist.json" },
      "recursive": false,
      "trackIntegrity": false,
      "contentPatterns": []
    }
  ]
}
```

Note the second entry omits `alertConditions`: a plain existence entry, so
it defaults to `["onPresence"]` — **it alerts because the file was found.**

### watchlist-state.json (app-managed; never served remotely)

```json
{
  "version": 1,
  "state": {
    "550e8400-e29b-41d4-a716-446655440000": {
      "lastChecked": "2026-07-30T12:00:00Z",
      "baselineHashes": {
        "/Users/x/Library/LaunchAgents/com.example.a.plist": "9f86d08…",
        "/Users/x/Library/LaunchAgents/com.example.b.plist": "60303ae…"
      },
      "findings": []
    }
  }
}
```
