#!/usr/bin/env python3
"""Survey lenses over docs/domain.md -- the passes that need judgment, not a verdict.

check-domain.py is the hard gate: it fails on things a script can prove wrong.
This one surfaces the categories where 23 review runs found defects by looking,
so that looking is exhaustive instead of improvised. It always exits 0; reading
the output is the work.

    scripts/lenses.py            all lenses
    scripts/lenses.py guards     one lens by name
"""
import io, re, sys

src = io.open("docs/domain.md", encoding="utf-8").read()
lines = src.split("\n")
blocks = re.findall(r"```(.*?)```", src, re.S)
prose = re.sub(r"```.*?```", "", src, flags=re.S)


def head(n, why):
    print(f"\n{'='*78}\n{n}\n  why: {why}\n{'='*78}")


def code_lines():
    for b in blocks:
        for l in b.split("\n"):
            yield re.sub(r"//.*", "", l).rstrip()


LENSES = {}


def lens(name, why):
    def deco(fn):
        LENSES[name] = (why, fn)
        return fn
    return deco


@lens("counted", "a count is right when written and nothing updates it when a list grows elsewhere")
def _counted():
    pat = re.compile(r"\b(Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten)\s+"
                     r"([a-z]+)\b")
    for para in prose.split("\n\n"):
        t = " ".join(para.split())
        for m in pat.finditer(t):
            print(f"  RE-COUNT  {t[max(0, m.start()-40):m.start()+70]}")


@lens("guards", "each guard is right about the side it covers; ask what input reaches the other")
def _guards():
    for l in code_lines():
        if re.search(r"\b(min|max|clamp)\s*\(", l):
            two = "clamp" in l or ("min(" in l and "max(" in l)
            print(f"  {'        ' if two else 'ONE-SIDED'} {' '.join(l.split())[:96]}")


@lens("divisions", "a denominator that can reach zero, and a rate that nothing bounds")
def _div():
    for l in code_lines():
        if re.search(r"/\s*[A-Za-z(]", l):
            print(f"  DENOM  {' '.join(l.split())[:96]}")


@lens("fallbacks", "?? reads as one value with two sources; only one branch may handle the empty case")
def _fb():
    for i, l in enumerate(lines):
        if "??" in l:
            print(f"  {i+1}: {' '.join(l.split())[:96]}")


@lens("ages", "59 1/2 states its rounding direction; every other threshold should too")
def _ages():
    for m in re.finditer(r"[^.]*age\(year\)[^.]*\.", src):
        print(f"  {' '.join(m.group(0).split())[:100]}")
    for m in re.finditer(r"[^.]*\b(59½|65|at the end of the tax year)\b[^.]*\.", prose):
        t = " ".join(m.group(0).split())
        if "round" in t or "whole\nyear" in t or "convention" in t:
            print(f"  STATED  {t[:96]}")


@lens("spans-vs-points", "a rule written for date ranges is usually silent about things dated to a year")
def _sp():
    for m in re.finditer(r"[^.]*\b(startYear|endYear|prorat\w+|active this year)\b[^.]*\.", prose):
        print(f"  SPAN RULE  {' '.join(m.group(0).split())[:96]}")
    print("\n  year-dated fields to test each rule against:")
    print("    OneTimeEvent.year · Asset.acquisitionYear · Asset.plannedSaleYear")


@lens("dichotomies", "a stated partition (A or B, only, never) may have a third case")
def _di():
    for m in re.finditer(r"[^.]*\b(only|Only|never|Never|either|neither|varies \w+ only)\b[^.]*\.", prose):
        t = " ".join(m.group(0).split())
        if len(t) > 45:
            print(f"  {t[:100]}")


@lens("sentinels", "a sentinel gets typed and reported, then derivations from it go unhandled")
def _sen():
    for s in ["notReachable", "alreadyCoasting"]:
        hits = [i + 1 for i, l in enumerate(lines) if s in l]
        print(f"  {s}: lines {hits}")
    print("\n  every site deriving from a solved retirement year must handle notReachable:")
    for i, l in enumerate(lines):
        if "solved `retirementYear`" in l or "retirementDurationYears" in l:
            print(f"    {i+1}: {' '.join(l.split())[:90]}")


@lens("deferrals", "an optimistic deferral the engine can detect needs a flag, not blanket UI prose")
def _def():
    d = src[src.index("## 13. Deferred"):]
    for l in d.split("\n"):
        if l.startswith("- "):
            print(f"  DIRECTION?  {' '.join(l.split())[:96]}")


@lens("ui", "obligations scattered across sections can contradict each other")
def _ui():
    for m in re.finditer(r"[^.]*\bUI (must|should|instructs|surfaces|can)\b[^.]*\.", src):
        print(f"  {' '.join(m.group(0).split())[:100]}")


@lens("lookups", "a table keyed by age or size may be indexed past its last published row")
def _lk():
    seen = {}
    for m in re.finditer(r"`?(\w+)\[([^\]]+)\](\[([^\]]+)\])?", src):
        t = m.group(0)
        if any(k in t for k in ("filingStatus", "status]", "stateCode][householdSize", "limitFamily")):
            continue
        if re.search(r"age|Age|Size|size|Year\]|year\]", t):
            tbl = m.group(1)
            # does any sentence naming this table also say how it behaves past its end?
            stated = any(tbl in p and re.search(r"saturat|Assumes birth year|increment|past its last|no extension rule", p)
                         for p in prose.split("\n\n"))
            seen.setdefault(tbl, stated)
    for tbl, stated in sorted(seen.items()):
        print(f"  {tbl:34} out-of-range behaviour stated: {'yes' if stated else 'NO'}")
    print("\n  ask of each NO: what index does an ordinary household reach, and is the row there")


@lens("derivations", "two fields derived from the same source diverge when only one is overridable")
def _der():
    rows = []
    for l in lines:
        m = re.match(r"^\| `([A-Za-z][A-Za-z0-9_]*)`\s*\|\s*([^|]*?)\s*\|\s*(.*)$", l)
        if m and re.search(r"[Dd]erived|[Dd]efault(s|ed) (from|to)", m.group(3)):
            n = " ".join(m.group(3).split())
            over = bool(re.search(r"overridable|but stored|and stored", n))
            rows.append((over, m.group(1), n[:60]))
    for over, f, n in rows:
        print(f"  {'OVERRIDABLE' if over else 'fixed      '}  {f:28} {n}")
    print("\n  siblings deriving from the same source must agree on overridability,")
    print("  or the fixed one keeps a default the overridden one has moved away from")


@lens("scope", "a field may sit at a wider scope than the computation that reads it")
def _scope():
    for owner, sec in [("Assumptions", "per Scenario"), ("TaxUnit", "per TaxUnit"),
                       ("Household", "per Household"), ("Person", "per Person")]:
        used = sorted(set(re.findall(owner + r"\.([A-Za-z][A-Za-z0-9_]*)", src)))
        if used:
            print(f"  {owner} ({sec}) read as: {', '.join(used)}")
    print("\n  check each is consumed at its own scope or wider, never narrower")


@lens("ordering", "'before X' can be true and still name too late a boundary")
def _ord():
    for m in re.finditer(r"[^.]*\b(before|after) §\d[^.]*\.", src):
        print(f"  {' '.join(m.group(0).split())[:100]}")


name = sys.argv[1] if len(sys.argv) > 1 else None
for n, (why, fn) in LENSES.items():
    if name and n != name:
        continue
    head(n, why)
    fn()
print(f"\n{len(LENSES)} lenses. Nothing here is a verdict; each list needs reading.")
