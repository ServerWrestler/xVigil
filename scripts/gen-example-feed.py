#!/usr/bin/env python3
"""Generate feeds/macos-persistence-example.json.

This script is the source of truth for the example feed: edit entries here,
then regenerate. Never edit the JSON by hand.

IDs are UUIDv5 values derived from each entry's slug. Integrity baselines
are keyed by entry ID, so never rename the slug of an existing entry.

After regenerating, run scripts/validate-feed.py, scripts/test-feed-patterns.py
and `swift test --filter ExampleFeedTests`.

Usage: scripts/gen-example-feed.py feeds/macos-persistence-example.json
"""
import json, uuid, sys
NS = uuid.UUID("6f1c1d52-3b0e-4c5a-9d57-2a7f0e4b8c11")
entries = []

def add(slug, target, label, notes, patterns=None, integrity=False, conds=None, recursive=False):
    patterns = patterns or []
    if conds is None:
        conds = (["onChange"] if integrity else []) + (["onMatch"] if patterns else [])
        if not conds: conds = ["onPresence"]
    e = {"id": str(uuid.uuid5(NS, slug)), "target": target, "label": label, "notes": notes.strip(),
         "recursive": recursive, "trackIntegrity": integrity,
         "contentPatterns": patterns, "alertConditions": conds}
    entries.append(e)

# ---------- launchd plists (XML plists only; binary plists are skipped by the checker) ----------
BAD = r"((/private)?(/var)?/tmp/|/var/folders/|/Users/Shared/)"
EXE = r"<key>Program(Arguments)?</key>\s*(<array>\s*)?<string>\s*"
LAUNCH_PATHS = [
    EXE + BAD,
    EXE + r"/[^<]*/\.[A-Za-z0-9_][^/<]*</string>",
    r"<key>ProgramArguments</key>\s*<array>\s*<string>[^<]*/((ba|z|da)?sh|python3?|perl|ruby|osascript|node)</string>\s*(<string>-[A-Za-z]+</string>\s*)*<string>[^<]*" + BAD,
]
LAUNCH_EXEC = [
    r"<key>(DYLD_[A-Z_]+|LD_PRELOAD)</key>",
    r"(?s)<string>-c</string>\s*<string>[^<]*\b(curl|wget|nc|ncat|openssl|python3?|perl|ruby|php|base64|osascript)\b[^<]*</string>",
    r"<string>[^<]*\b(curl|wget)\b[^<]*\|\s*(ba|z)?sh\b",
    r"/dev/tcp/",
    r"base64\s+(-d|-D|--decode)",
    r"<string>\s*/usr/bin/osascript</string>",
]
for slug, tgt, where, tech in [
    ("agents-user", "~/Library/LaunchAgents/*.plist", "user LaunchAgents", "T1543.001"),
    ("agents-sys", "/Library/LaunchAgents/*.plist", "system LaunchAgents", "T1543.001"),
    ("daemons-sys", "/Library/LaunchDaemons/*.plist", "LaunchDaemons", "T1543.004"),
]:
    add(f"launch-paths-{slug}", tgt, f"Persistence: {where} - runs from temp/shared/hidden path",
        f"Medium. MITRE {tech}. Flags plists whose launched executable lives in /tmp, /var/folders or the shared users "
        "folder, has a hidden basename, or is a shell/interpreter whose script or command references those temp paths. "
        "Log paths (StandardOutPath etc.) are deliberately not matched. "
        "XML plists only: binary plists are skipped by the content scanner.", LAUNCH_PATHS)
    add(f"launch-exec-{slug}", tgt, f"Persistence: {where} - shell/interpreter one-liner or dylib injection",
        f"High. MITRE {tech}, T1574.006. DYLD_*/LD_PRELOAD environment keys, sh -c wrappers around curl/nc/python/osascript, "
        "curl|sh, /dev/tcp, base64 -d, or osascript as the launched program. XML plists only.", LAUNCH_EXEC)
add("agents-user-appleprefix", "~/Library/LaunchAgents/com.apple.*.plist", "Persistence: user LaunchAgent masquerading as Apple",
    "Medium. MITRE T1036.005 / T1543.001. Apple's own launch items live on the sealed system volume, not in the "
    "user's LaunchAgents folder. Alerts on any file there with a com.apple. prefix. Known benign leftover: "
    "com.apple.CSConfigDotMacCert-*.plist from the MobileMe era. Review the program path.",
    conds=["onPresence"])

# ---------- shell init ----------
SHELL = [
    r"\b(curl|wget)\b[^\n]*\|\s*(sudo\s+)?(ba|z)?sh\b",
    r"\beval\s+[\"']?\$\(\s*(curl|wget)\b",
    r"base64\s+(-d|-D|--decode)",
    r"/dev/tcp/",
    r"(?m)^\s*(export\s+)?DYLD_(INSERT_LIBRARIES|FRAMEWORK_PATH|LIBRARY_PATH)=",
    r"\b(nohup|exec|source)\s+(/private)?(/var)?/tmp/",
    r"(?m)^\s*(alias\s+(sudo|su)=|(function\s+)?(sudo|su)\s*\(\s*\)\s*\{)",
]
SHELL_NOTE = ("MITRE T1546.004. Content match for download-and-execute, reverse-shell, dylib-injection and "
              "sudo/su shadowing idioms. The alias/function check can fire on legitimate `alias sudo='sudo '`. ")
for slug, tgt, label in [
    ("zsh-rc-env", "~/.zsh[er]*", "Persistence: ~/.zshrc and ~/.zshenv (and backups) - malicious idioms"),
    ("zsh-login", "~/.z[pl]*", "Persistence: ~/.zprofile, ~/.zlogin, ~/.zlogout - malicious idioms"),
    ("bash-rc", "~/.bash[_r][pcl]*", "Persistence: ~/.bashrc, ~/.bash_profile/login/logout - malicious idioms"),
    ("profile", "~/.profile", "Persistence: ~/.profile - malicious idioms"),
]:
    add(f"shell-{slug}", tgt, label, "Medium. " + SHELL_NOTE + ("Globs deliberately exclude *_history and *_sessions." if "*" in tgt else ""), SHELL)
for slug, tgt, label in [
    ("etc-z", "/etc/z*", "Persistence: /etc zsh startup files - malicious idioms"),
    ("etc-profile", "/etc/profile", "Persistence: /etc/profile - malicious idioms"),
    ("etc-bashrc", "/etc/bashrc", "Persistence: /etc/bashrc - malicious idioms"),
]:
    add(f"shell-{slug}", tgt, label, "High. System-wide startup file: root-owned, so any hit implies privileged tampering. " + SHELL_NOTE, SHELL)
add("etc-zshenv", "/etc/zshenv", "Persistence: /etc/zshenv exists",
    "High. Sourced by every zsh invocation, interactive or not. Not present on a stock macOS install (verify on your OS version).", conds=["onPresence"])
add("etc-zlog", "/etc/zlog*", "Persistence: /etc/zlogin or /etc/zlogout exists",
    "High. Not present on a stock macOS install (verify on your OS version).", conds=["onPresence"])

# ---------- scheduled execution ----------
PERIODIC = [r"\b(curl|wget)\b[^\n]*\|\s*(sudo\s+)?(ba|z)?sh\b", r"base64\s+(-d|-D|--decode)", r"/dev/tcp/", r"\bosascript\b"]
for p in ("daily", "weekly", "monthly"):
    add(f"periodic-{p}", f"/etc/periodic/{p}/*", f"Persistence: periodic {p} scripts - malicious idioms",
        "Medium. MITRE T1053.003-adjacent (periodic runs via launchd). Runs as root. Content match only: new, "
        "benign scripts are not flagged (the checker has no new-file condition).", PERIODIC)
add("periodic-local", "/etc/[dwm]*ly.local", "Persistence: periodic *.local override exists",
    "Medium. /etc/daily.local, weekly.local and monthly.local run as root from the periodic job. Not present by default.", conds=["onPresence"])
add("emond", "/etc/emond.d/rules/*.plist", "Persistence: emond rule runs a command",
    "High. MITRE T1546.014. Event Monitor was removed in macOS Ventura. Matches RunCommand actions, the persistence mechanism; "
    "the stock SampleRules.plist that can survive upgrades does not use one.", [r"<string>\s*RunCommand\s*</string>"])
# No crontab entry: /var/at/tabs is root-only (mode 700), so xVigil can never
# list it, and a rule that can't fire would look like "no crontabs found".
add("folder-actions", "~/Library/Scripts/Folder Action Scripts/*", "Persistence: user Folder Action script exists",
    "Medium. MITRE T1546 (event-triggered execution; Folder Actions have no dedicated sub-technique). Folder Action Scripts in the user Library are not present by default.", conds=["onPresence"])

# ---------- remote access / auth ----------
add("ssh-authkeys", "~/.ssh/authorized_keys*", "Access: SSH authorized_keys exists",
    "Medium. MITRE T1098.004. Alerts when any authorized_keys file exists. Expected to fire on Macs that legitimately accept SSH logins; "
    "drop this entry for those hosts.", conds=["onPresence"])
add("ssh-rc-user", "~/.ssh/rc", "Persistence: ~/.ssh/rc exists",
    "High. Executed on every SSH login. Not present by default.", conds=["onPresence"])
add("ssh-rc-sys", "/etc/ssh/sshrc", "Persistence: /etc/ssh/sshrc exists",
    "High. Executed on every SSH login for all users. Not present by default.", conds=["onPresence"])
add("ssh-config-user", "~/.ssh/config", "Access: ~/.ssh/config runs local commands",
    "Medium. PermitLocalCommand yes / LocalCommand runs a command on each connection. ProxyCommand is intentionally not matched (common in bastion setups).",
    [r"(?mi)^\s*(PermitLocalCommand\s+yes|LocalCommand\s+\S)"])
SSHD = [r"(?mi)^\s*PermitRootLogin\s+yes\b", r"(?mi)^\s*PermitEmptyPasswords\s+yes\b",
        r"(?mi)^\s*AuthorizedKeysCommand(User)?\s+\S", r"(?mi)^\s*GatewayPorts\s+(yes|clientspecified)\b",
        r"(?mi)^\s*PermitTunnel\s+(yes|point-to-point|ethernet)\b"]
add("sshd-config", "/etc/ssh/sshd_config", "Access: sshd_config weakened or changed",
    "Medium. Hash change plus content match for root login, empty passwords, AuthorizedKeysCommand, GatewayPorts, PermitTunnel. Expect a change alert after macOS updates that rewrite it.", SSHD, integrity=True)
add("sshd-config-d", "/etc/ssh/sshd_config.d/*", "Access: sshd_config.d drop-in weakened or changed",
    "Medium. Same checks as sshd_config, applied to drop-in files.", SSHD, integrity=True)
PAM = [r"\bpam_exec\.so\b", r"\bpam_script\b",
       r"(?m)^(?!\s*#)(?![^\n]*pam_reattach\.so)[^\n]*\s/\S+\.so\b"]
add("pam-d", "/etc/pam.d/*", "Auth: PAM config changed or loads external module",
    "High. MITRE T1556.003. Hash change plus pam_exec/pam_script or a module loaded by absolute path (pam_reattach is exempted). "
    "Expect one change alert after macOS updates that touch PAM files.", PAM, integrity=True)
add("pam-sudo-local", "/etc/pam.d/sudo_local", "Auth: sudo_local has modules beyond Touch ID",
    "High. MITRE T1556.003. sudo_local is the supported place to enable Touch ID (pam_tid) and smartcards. Any other auth/account/password/session "
    "module is flagged (pam_reattach exempted), including third-party pam_watchid.",
    [r"(?m)^\s*(auth|account|password|session)\s+\S+\s+(?!pam_tid\.so|pam_smartcard\.so|\S*pam_reattach\.so)\S+\.so\b"], integrity=True)

# ---------- security controls / traffic ----------
add("libval", "/Library/Preferences/com.apple.security.libraryvalidation.plist", "Defense evasion: library validation preference exists",
    "High. MITRE T1562.001. Created when DisableLibraryValidation is set, which lets unsigned or foreign-signed dylibs load into hardened apps.",
    conds=["onPresence"])
add("hosts", "/etc/hosts", "Traffic: /etc/hosts changed or blocks Apple security hosts",
    "Medium. Hash change plus entries for Apple OCSP, update and device-management hosts. Some privacy-minded users block ocsp.apple.com deliberately.",
    # Case-insensitive, and the host must be a whole hosts-file field, so
    # lookalikes such as ocsp.apple.com.example.net don't match.
    [r"(?mi)^[^#\n]*\s((ocsp2?|gdmf|mesu|swscan|swdist|oscdn)\.apple\.com|updates\.cdn-apple\.com)(?=[ \t#]|$)"], integrity=True)
NMH = [r"\"path\"\s*:\s*\"(/private)?(/var)?/tmp/", r"\"path\"\s*:\s*\"/var/folders/",
       r"\"path\"\s*:\s*\"/Users/Shared/", r"\"path\"\s*:\s*\"[^\"]*/\.[A-Za-z0-9_][^/\"]*\""]
for slug, tgt, label in [
    ("chrome-user", "~/Library/Application Support/Google/Chrome/NativeMessagingHosts/*.json", "Browser: Chrome native messaging host (user) runs from temp/hidden path"),
    ("chrome-sys", "/Library/Google/Chrome/NativeMessagingHosts/*.json", "Browser: Chrome native messaging host (system) runs from temp/hidden path"),
    ("firefox-user", "~/Library/Application Support/Mozilla/NativeMessagingHosts/*.json", "Browser: Firefox native messaging host runs from temp/hidden path"),
]:
    add(f"nmh-{slug}", tgt, label,
        "Medium. MITRE T1176.001. Native messaging hosts let a browser extension execute a local binary. Flags a host whose binary lives in temp, shared or hidden paths.", NMH)

if len(sys.argv) != 2:
    sys.exit(__doc__)
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"version": 1, "entries": entries}, f, indent=2, sort_keys=True)
    f.write("\n")
print(len(entries), "entries")
