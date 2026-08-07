# The xVigil Dashboard

Open it from the menu bar shield → **Dashboard…**, or by clicking any banner.
While the dashboard is open, xVigil shows a Dock icon; close it and the app
returns to the menu bar. Six sections in the sidebar:

## Detections

The one place every "something was found" lands, regardless of source:
XProtect log detections (a background sweep re-reads the last 24 hours of
XProtect activity every 30 minutes), on-demand or scheduled scan hits, and
File Monitor alerts. Any active finding also turns the menu bar shield red
and banners the popover — you never have to open this pane to learn that
something happened; the pane is where you investigate it.

Select a finding for its source, time, full detail, and — when it points at
a file — Reveal in Finder. An empty pane shows a green "No detections":
verifiable quiet, not silence you have to trust.

## Quarantine Events

Every download and attachment macOS has recorded in its quarantine database —
the bookkeeping behind Gatekeeper's "downloaded from the internet" prompts.
The list covers every row still in the database (macOS prunes it on its own
schedule) and loads as you scroll.

- **Search** matches URLs, sender fields, and app names.
- **Filters** are built from your actual data: the agent list is the apps
  that have really quarantined files on this Mac, and the type list contains
  only type numbers that occur in your database (including undocumented ones
  like GarageBand's "Type 7").
- **Select an event** for the full record plus three investigations:
  - **On disk** — locates the actual file by matching the event's UUID
    against `com.apple.quarantine` extended attributes in the likely
    locations (Downloads, Desktop, Documents, Applications, Messages and
    Mail attachment folders). If a location can't be read, the pane says so
    and explains that Full Disk Access would fix it — an incomplete search
    is never passed off as "not found." The most likely location is searched
    first, and the whole lookup is hard-bounded at 15 seconds, so the pane
    always resolves rather than spinning.
  - **Gatekeeper today** — a live `spctl` assessment of the found file and
    its full code-signature chain via `codesign`.
  - **Log context** — XProtect/Gatekeeper unified-log entries from ±60
    seconds around the event.

## XProtect Activity

What Apple's own malware scanner has been doing, read from the unified log
and clustered by time gap into logical runs — a scheduled scan that emits
hundreds of log lines across several helper processes collapses into one
row. Rows are badged by significance (possible detection / Gatekeeper
assessment / scan activity / service chatter); select one to read the raw
entries.

## On-Demand Scan

Active scanning of the places Apple's tools never proactively check, using
your own ClamAV install (`brew install clamav`). The engine section shows
whether the clamd daemon is running (fast scans) or scans fall back to
`clamscan` (slow start), and how old your signature databases are — stale
signatures get a warning, because they give false confidence.

Pick folders, scan on demand, or enable the daily/weekly schedule. Findings
stream in live, feed the Detections pane and red shield, and are
**report-only**: xVigil tells you what it found and where; it never
quarantines or deletes anything.

## File Monitor

A file watchlist combining four checks per entry:

1. **Existence** — is the file there? Listing a path because *finding it is
   bad news* (IOC hunting) is the default: a plain entry alerts when the
   file appears. Flip to alert-on-missing for sentinel files.
2. **Integrity** — SHA-256 baseline on first sight, alert when the hash
   changes.
3. **Pattern targets** — globs and recursive directories (`~/Library/
   LaunchAgents/*.plist`), capped at 500 files per entry.
4. **Content inspection** — regex search inside readable text files
   (skips binaries and files over 1 MB).

Entries are yours (created in the pane, stored in
`~/Library/Application Support/xVigil/watchlist.json`, hand-editable) or
fetched from a remote HTTPS feed — an IOC list you or your team publish.
Remote refreshes replace remote entries but never touch local ones or
integrity baselines. Checks run on demand or hourly/daily; alerts land in
Detections like everything else. Report-only, like the scanner.

## Protection Status

The health snapshot: Gatekeeper enabled, XProtect definition and Remediator
versions. Also home to app settings — start at login (registers in System
Settings → Login Items), and the update check (daily/weekly/monthly, a
single anonymous request to GitHub Releases; new versions are linked, never
auto-installed).
