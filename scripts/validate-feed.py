#!/usr/bin/env python3
"""Validate an xVigil remote watchlist feed against the app's fetch-time limits.

Mirrors WatchlistFetcher.validate (entry/pattern caps) and the WatchlistEntry
schema. Regexes are compiled with Python's `re` as an approximation of
NSRegularExpression (ICU): fine for the syntax feeds use, but not a guarantee.

Usage: scripts/validate-feed.py feeds/*.json
"""
import json, re, sys, uuid

MAX_ENTRIES, MAX_PATTERNS, MAX_PATTERN_LEN = 200, 32, 512
CONDITIONS = {"onPresence", "onAbsence", "onChange", "onMatch"}
TYPES = {"id": str, "target": str, "label": str, "notes": str, "recursive": bool,
         "trackIntegrity": bool, "contentPatterns": list, "alertConditions": list}
ALLOWED = {"id", "target", "label", "notes", "recursive", "trackIntegrity", "contentPatterns", "alertConditions"}

def check(path):
    errs = []
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError) as ex:
        return [f"unreadable or invalid JSON: {ex}"]
    if not isinstance(doc, dict):
        return ["top level must be an object"]
    if doc.get("version") != 1:
        errs.append("version must be 1")
    entries = doc.get("entries")
    if not isinstance(entries, list):
        return ["entries must be an array"]
    if len(entries) > MAX_ENTRIES:
        errs.append(f"{len(entries)} entries (limit {MAX_ENTRIES})")
    ids = set()
    for i, e in enumerate(entries):
        if not isinstance(e, dict):
            errs.append(f"#{i}: entry must be an object")
            continue
        name = e.get("label", f"#{i}")
        # A type mismatch makes Swift's decoder reject the whole feed, not one entry.
        for k, t in TYPES.items():
            if k in e and not isinstance(e[k], t):
                errs.append(f"{name}: {k} must be {t.__name__}")
        if any(not isinstance(x, str) for x in e.get("contentPatterns", []) if isinstance(e.get("contentPatterns"), list)):
            errs.append(f"{name}: contentPatterns must be strings")
        for k in e:
            if k not in ALLOWED:
                errs.append(f"{name}: unknown key {k!r} (feeds must not set 'source')")
        try:
            u = uuid.UUID(e["id"])
            if str(u) != e["id"]: errs.append(f"{name}: id not canonical lowercase")
            if e["id"] in ids: errs.append(f"{name}: duplicate id")
            ids.add(e["id"])
        except Exception:
            errs.append(f"{name}: missing or invalid id (feeds need stable UUIDs so baselines survive refreshes)")
        if not e.get("target"): errs.append(f"{name}: empty target")
        pats = e.get("contentPatterns", [])
        if len(pats) > MAX_PATTERNS: errs.append(f"{name}: {len(pats)} patterns (limit {MAX_PATTERNS})")
        for p in (x for x in pats if isinstance(x, str)):
            if len(p) > MAX_PATTERN_LEN: errs.append(f"{name}: pattern longer than {MAX_PATTERN_LEN}")
            try: re.compile(p)
            except re.error as ex: errs.append(f"{name}: bad regex {p!r}: {ex}")
        conds = e.get("alertConditions", [])
        if not isinstance(conds, list) or not conds or set(map(str, conds)) - CONDITIONS: errs.append(f"{name}: invalid alertConditions {conds}")
        if "onMatch" in conds and not pats: errs.append(f"{name}: onMatch without contentPatterns")
        if "onChange" in conds and not e.get("trackIntegrity"): errs.append(f"{name}: onChange without trackIntegrity")
        if "onAbsence" in conds and any(c in e.get("target", "") for c in "*?["):
            errs.append(f"{name}: onAbsence needs a literal target")
    return errs

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    bad = 0
    for p in sys.argv[1:]:
        errs = check(p)
        print(f"{p}: {'OK' if not errs else 'FAILED'}")
        for e in errs: print("  -", e)
        bad += bool(errs)
    sys.exit(1 if bad else 0)
