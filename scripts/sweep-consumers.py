#!/usr/bin/env python3
"""Consumer sweep: after changing an identifier, show everything that reads it.

Six of the nine defects this session's edits introduced were the same mistake --
a field was added, removed, or redefined and some consumer elsewhere went stale.
Run this on every identifier a change touches, before calling the change done.

    scripts/sweep-consumers.py acquisitionYear Contribution.startYear
    scripts/sweep-consumers.py --diff        # identifiers from the working diff
"""
import io, re, subprocess, sys

PATH = "docs/domain.md"
src = io.open(PATH, encoding="utf-8").read()
lines = src.split("\n")

# Places a stale consumer is most likely to hide, learned from the ones that did.
HOTSPOTS = [
    (r"^## 2\.", "§2 entity tree"),
    (r"^### 3\.\d", "an entity table"),
    (r"^## 4\.", "§4 pipeline"),
    (r"^## 5\.", "§5 derived quantities"),
    (r"^## 6\.", "§6 loop / maintenance rules"),
    (r"^## 9\.", "§9 FIRE variants"),
    (r"^## 10\.", "§10 snapshot trigger and digest"),
    (r"^## 11\.", "§11 export inventory"),
    (r"^## 12\.", "§12 invariants"),
    (r"^## 13\.", "§13 deferred"),
]


def section_of(idx):
    sec = "(front matter)"
    for i in range(idx, -1, -1):
        if re.match(r"^#{2,4} ", lines[i]):
            return lines[i].strip("# ").strip()
    return sec


def hotspot_of(idx):
    for i in range(idx, -1, -1):
        for pat, name in HOTSPOTS:
            if re.match(pat, lines[i]):
                return name
    return None


def sweep(ident):
    bare = ident.split(".")[-1]
    hits = [(i, l) for i, l in enumerate(lines) if re.search(r"\b" + re.escape(bare) + r"\b", l)]
    print(f"\n=== {ident}  ({len(hits)} reference(s))")
    if not hits:
        print("    NONE -- declared and never read, or already removed")
        return
    seen = {}
    for i, l in hits:
        seen.setdefault(hotspot_of(i) or section_of(i), []).append((i + 1, " ".join(l.split())[:96]))
    for where, rows in seen.items():
        print(f"  [{where}]")
        for n, t in rows:
            print(f"      {n}: {t}")
    missing = [n for _, n in HOTSPOTS if n not in seen]
    if missing:
        print(f"  not referenced in: {', '.join(dict.fromkeys(missing))}")
        print("      ^ check each: does it need to know about this change?")


def from_diff():
    try:
        d = subprocess.run(["git", "diff", "-U0", "--", PATH],
                           capture_output=True, text=True, check=True).stdout
    except Exception as e:
        print("could not read git diff:", e)
        return []
    ids = set()
    for l in d.split("\n"):
        if l.startswith(("+", "-")) and not l.startswith(("+++", "---")):
            ids |= set(re.findall(r"`([a-zA-Z][A-Za-z0-9_]{3,})`", l))
    return sorted(ids)


args = sys.argv[1:]
if not args:
    print(__doc__)
    sys.exit(2)
targets = from_diff() if args[0] == "--diff" else args
if args[0] == "--diff":
    print(f"identifiers touched by the working diff: {len(targets)}")
for t in targets:
    sweep(t)
