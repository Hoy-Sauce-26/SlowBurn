#!/usr/bin/env python3
"""One command that runs every domain check and answers PASS or FAIL.

    scripts/check.py            everything
    scripts/check.py --quiet    the verdict and any failures, nothing else

The gate decides the verdict. The sweep and the lenses are advisory: they point
at what to read, and neither can fail a run on its own.
"""
import io, re, subprocess, sys

QUIET = "--quiet" in sys.argv
DOC = "docs/domain.md"
G, R, Y, B, X = "\033[32m", "\033[31m", "\033[33m", "\033[1m", "\033[0m"
if not sys.stdout.isatty():
    G = R = Y = B = X = ""


def run(*cmd):
    p = subprocess.run([sys.executable, *cmd], capture_output=True, text=True)
    return p.returncode, p.stdout


def main():
    try:
        src = io.open(DOC, encoding="utf-8").read()
    except OSError:
        print(f"{R}FAIL{X}  no {DOC} here. Run this from the repository root.")
        return 1

    words = len(src.split())
    sec12 = re.search(r"^## 12\.(.*?)^## 13\.", src, re.S | re.M).group(1)
    invs = [int(i) for i in re.findall(r"^(\d+)\. ", sec12, re.M)]
    flags = len(re.findall(r"`([a-z][A-Za-z]+)`", re.search(
        r"`flags\[\]` array \((.*?)\)\.", src, re.S).group(1)))
    if not QUIET:
        print(f"\n{B}{DOC}{X}  {words:,} words · {flags} flags · "
              f"{max(invs)} invariants\n")

    # 1. the gate: the only thing that decides the verdict
    code, out = run("scripts/check-domain.py")
    failed, detail, inside = [], [], False
    for l in out.split("\n"):
        if l.startswith("FAIL"):
            failed.append(l)
            inside = True
        elif not l.startswith("        "):
            inside = False
        if inside:
            detail.append(l)
    if code == 0:
        if not QUIET:
            print(f"  {G}[PASS]{X} gate      every mechanical check clean")
    else:
        print(f"  {R}[FAIL]{X} gate      {len(failed)} check(s) tripped")
        for l in detail:
            print(f"         {l}")

    if QUIET:
        print(f"{(G + 'PASS') if code == 0 else (R + 'FAIL')}{X}")
        return code

    # 2. the sweep: what your uncommitted edits touched, and where it is not read
    _, sw = run("scripts/sweep-consumers.py", "--diff")
    touched = re.search(r"identifiers touched by the working diff: (\d+)", sw)
    n = int(touched.group(1)) if touched else 0
    if n == 0:
        print(f"  {G}[ ok ]{X} sweep     no uncommitted changes to sweep")
    elif n > 40:
        print(f"  {Y}[read]{X} sweep     {n} identifier(s) changed, too many to read")
        print(f"         commit what is settled; the sweep earns its keep on a small diff")
    else:
        stale = len(re.findall(r"^  not referenced in:", sw, re.M))
        print(f"  {Y}[read]{X} sweep     {n} identifier(s) changed, "
              f"{stale} with sections that never mention them")
        print(f"         scripts/sweep-consumers.py --diff")

    # 3. the lenses: judgment, never a verdict
    _, ln = run("scripts/lenses.py")
    n_lens = re.search(r"(\d+) lenses", ln)
    body = len([l for l in ln.split("\n") if l.startswith("  ") and l.strip()])
    print(f"  {Y}[read]{X} lenses    {n_lens.group(1) if n_lens else '?'} lenses, "
          f"{body} lines needing a human")
    print(f"         scripts/lenses.py")

    print(f"\n{(G + 'PASS') if code == 0 else (R + 'FAIL')}{X}"
          f"{'' if code == 0 else '  fix the gate above, then run this again'}\n")
    return code


sys.exit(main())
