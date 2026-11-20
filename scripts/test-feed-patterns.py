#!/usr/bin/env python3
"""Check the example feed's patterns and globs against its sample fixture.

Reads feeds/samples/macos-persistence-example.json. Each content group lists
strings that must match (and must not match) every entry whose label starts
with one of the group's prefixes. Glob samples check which file names each
entry's target resolves.

This uses Python's re and fnmatch, so it runs without Swift. The
authoritative run is `swift test --filter ExampleFeedTests`, which uses ICU
(the app's regex engine) and the app's own resolver.

Usage (from the repo root): scripts/test-feed-patterns.py
"""
import fnmatch, json, os, re, sys

FEED = "feeds/macos-persistence-example.json"
SAMPLES = "feeds/samples/macos-persistence-example.json"


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main():
    entries = load(FEED)["entries"]
    samples = load(SAMPLES)
    fails = 0
    covered = set()

    def select(prefixes):
        return [e for e in entries if any(e["label"].startswith(p) for p in prefixes)]

    for group in samples["contentGroups"]:
        selected = [e for e in select(group["entries"]) if e["contentPatterns"]]
        if not selected:
            print("NO ENTRIES", group["name"]); fails += 1
        for e in selected:
            covered.add(e["id"])
            hit = lambda s: any(re.search(p, s) for p in e["contentPatterns"])
            for s in group["match"]:
                if not hit(s): print("MISS  ", e["label"], repr(s)); fails += 1
            for s in group["noMatch"]:
                if hit(s): print("FALSEP", e["label"], repr(s)); fails += 1

    for e in entries:
        if e["contentPatterns"] and e["id"] not in covered:
            print("UNTESTED", e["label"]); fails += 1

    for g in samples["globs"]:
        selected = select([g["entry"]])
        if len(selected) == 0:
            print("NO ENTRY", g["entry"]); fails += 1
        for e in selected:
            pattern = os.path.basename(e["target"])
            if fnmatch.fnmatchcase(g["file"], pattern) != g["resolves"]:
                print("GLOB  ", e["target"], g["file"], "want", g["resolves"]); fails += 1

    print("failures:", fails)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
