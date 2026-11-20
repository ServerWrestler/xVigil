# Example remote feed: macOS persistence and tampering

`macos-persistence-example.json` is a reference feed in the format xVigil's
File Monitor fetches from a remote HTTPS URL. It watches the places macOS
malware and intruders most often use to persist, escalate, or weaken
defenses. It doubles as a worked example of the feed schema.

To use it, open the dashboard's **File Monitor**, paste this URL into
**Remote source**, and click **Fetch now**:

```
https://raw.githubusercontent.com/ServerWrestler/xVigil/main/feeds/macos-persistence-example.json
```

Report-only, like everything in xVigil: nothing is quarantined or deleted.
Fetched entries sit alongside your own and never replace them.

## Schema

```
{ "version": 1,
  "entries": [
    { "id": "stable-uuid",
      "target": "~/Library/LaunchAgents/*.plist",
      "label": "Short human name",
      "notes": "Severity, MITRE ID, false-positive notes",
      "recursive": false,
      "trackIntegrity": false,
      "contentPatterns": ["regex", "..."],
      "alertConditions": ["onPresence" | "onAbsence" | "onChange" | "onMatch"] } ] }
```

- **Stable `id`s matter.** Integrity baselines are keyed by entry ID, and an
  entry without an `id` gets a new random one on every fetch, which throws
  its baseline away.
- **Don't set `source`.** The fetcher tags every fetched entry as remote
  regardless of what the feed says.
- **Fetch limits** (enforced by `WatchlistFetcher`): 200 entries, 32
  patterns per entry, 512 characters per pattern, HTTPS only. One wrong
  field type rejects the whole feed, not just that entry.
- **Scan limits** (enforced by `WatchlistChecker`): 500 files per entry,
  text files up to 1 MB, 2 s regex budget per file.
- **Alert semantics.** `onPresence` alerts for every file the target
  resolves to, so it is only right for paths that should not exist. For
  directories that legitimately hold files, use `onMatch` patterns.
- **Globs that match nothing are silent**, and so are directories xVigil
  can't list. A glob into a root-only directory never fires.

## Editing the example feed

`scripts/gen-example-feed.py` is the source of truth. Edit entries there,
never the JSON. Each ID is a UUIDv5 derived from the entry's slug, so never
rename the slug of an existing entry.

```sh
scripts/gen-example-feed.py feeds/macos-persistence-example.json
scripts/validate-feed.py feeds/*.json
scripts/test-feed-patterns.py
swift test --filter ExampleFeedTests
```

- `validate-feed.py` checks any feed (not just this one) for schema, field
  types, limits, ID uniqueness, and that each regex compiles. Run it before
  publishing your own feed.
- `samples/macos-persistence-example.json` holds strings each pattern must
  and must not match, plus file names each glob must and must not resolve.
  Every entry with patterns needs at least one sample group.
- `test-feed-patterns.py` checks those samples with Python's `re`, so it
  runs without Swift.
- `ExampleFeedTests` checks the same samples with the app's own code: its
  decoder and fetch limits, ICU regexes (the engine the app uses), the
  content scanner, and the glob resolver. That is the authoritative check.

## What the example covers

| Area | Entries | Method |
| --- | --- | --- |
| launchd plists (user/system agents, daemons) | 7 | content match on the launched executable's path, one-liners, `DYLD_*`; presence of `com.apple.*` in user agents |
| Shell startup (user and `/etc`) | 9 | content match for download-and-execute, reverse shell, dylib injection, `sudo` shadowing; presence of stock-absent `/etc/zshenv`, `/etc/zlog*` |
| Periodic, emond, Folder Actions | 6 | content match (periodic scripts, emond `RunCommand`); presence (`*.local` overrides, Folder Action scripts) |
| SSH (`authorized_keys`, `rc`, config, sshd) | 6 | presence, content match, integrity |
| PAM | 2 | integrity plus external-module match; `sudo_local` allows only `pam_tid`/`pam_smartcard` (and `pam_reattach`) |
| Library validation, `/etc/hosts` | 2 | presence; integrity plus Apple-host match |
| Browser native messaging hosts | 3 | content match on host binary path |

Each entry's `notes` carries a severity (High/Medium), a MITRE ATT&CK ID where
one applies, and the known false-positive sources.

There is no crontab entry. User crontabs live in `/var/at/tabs`, which is
root-only, so xVigil can never list it, and a rule that can't fire would
read as "no crontabs found".

## Verified on a live Mac

Run with xVigil's checker on macOS 27.2.1, a developer Mac with Homebrew and
Xcode:

- All 35 entries checked 51 files and raised **no alerts** and no errors.
- `/etc/zshenv`, `/etc/zlogin`, `/etc/zlogout` and `/etc/emond.d` are absent.
- Stock `/etc/zshrc`, `/etc/zprofile`, `/etc/zshrc_Apple_Terminal`,
  `/etc/profile`, `/etc/bashrc`, all 25 files in `/etc/pam.d`, `/etc/hosts`,
  `/etc/ssh/sshd_config` and `/etc/ssh/sshd_config.d/100-macos.conf`
  produce no matches.
- `/var/at/tabs` is `drwx------ root`, unlistable even with Full Disk
  Access (hence no crontab entry).

That is one Mac. Expect alerts from the presence entries on Macs that
legitimately accept SSH logins (`authorized_keys`), use Folder Actions, or
carry old `com.apple.*` user agents, and one `onChange` alert after a macOS
update rewrites `sshd_config` or PAM files.

## What this checker cannot express yet

These came up while building the feed. They are limits of the current
`WatchlistChecker`, not of the idea:

1. **New file in a directory.** Integrity treats first sighting as a
   baseline, so a brand-new LaunchAgent cannot alert unless its contents
   match a pattern. An `onNewFile` condition (path not in the prior
   baseline) would close the biggest gap.
2. **Directories and bundles as targets.** Only regular files resolve, and
   enumeration skips package descendants. That rules out
   `/Library/Security/SecurityAgentPlugins`, Spotlight importers, system
   extensions, and app-bundle tampering. It also misses launch agents that
   modern apps register from inside their own bundle with `SMAppService`.
3. **Binary plists.** The NUL-byte sniff skips them, so `LoginHook` in
   `com.apple.loginwindow.plist` and any `defaults`-written launch plist are
   invisible to content patterns. Decoding plists to XML before scanning
   would fix this.
4. **Unlistable directories.** A glob into a directory xVigil can't read
   is silent, the same as one that matched nothing. Reporting it as an
   error would make gaps like `/var/at/tabs` visible.
5. **Root-only files.** `/etc/sudoers` and `/etc/sudoers.d/*` can't be
   read or hashed by an unprivileged app.
6. **Databases.** The Background Task Management database and `TCC.db` are
   binary and change constantly. Endpoint Security events suit them better
   than file watching.
