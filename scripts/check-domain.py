#!/usr/bin/env python3
"""Pass 0 of docs/domain-review-plan.md: mechanical checks over docs/domain.md.

Run after every edit.  Exit code 1 if any FAIL check trips.
"""
import io, re, sys, collections

PATH = "docs/domain.md"
src = io.open(PATH, encoding="utf-8").read()
lines = src.split("\n")

# Internal Revenue Code sections cited as authority, not document cross-references.
IRC = {"72", "86", "121", "125", "129", "132", "401", "402", "408", "415", "1250", "1411"}

fails, notes = [], []


def fail(check, items):
    if items:
        fails.append((check, items))


def note(check, items):
    if items:
        notes.append((check, items))


# --- 1. dangling document cross-references -----------------------------------
heads = set(re.findall(r"^#{2,4} (\d+(?:\.\d+)*)", src, re.M))
refs = collections.Counter()
for m in re.finditer(r"§(\d+(?:\.\d+)*)(?![A-Za-z0-9(])", src):
    refs[m.group(1)] += 1
fail("dangling §refs",
     sorted(f"§{r} ({n}x)" for r, n in refs.items()
            if r not in heads and r not in IRC))

# --- 2. flags declared in §6 but never defined --------------------------------
fl = re.search(r"`flags\[\]` array \((.*?)\)\.", src, re.S)
if fl:
    FLAGS = re.findall(r"`([a-z][A-Za-z]+)`", fl.group(1))
    fail("flags with no definition outside §6's list",
         [f for f in FLAGS if src.count(f) < 2])
    note("flags declared", [f"{len(FLAGS)} total"])
else:
    fail("flags list", ["§6 flags[] array not found"])

# --- 3. invariant numbering ---------------------------------------------------
inv = re.search(r"## 12\. Invariants(.*?)\n## 13\.", src, re.S)
if inv:
    nums = [int(n) for n in re.findall(r"^(\d+)\. ", inv.group(1), re.M)]
    fail("invariant numbering",
         [] if nums == list(range(1, len(nums) + 1)) else [str(nums)])
    note("invariants", [f"1..{len(nums)}"])

# --- 4. acronym casing inside identifiers -------------------------------------
idents = set(re.findall(r"`([a-zA-Z][A-Za-z0-9_.]*)`", src))
fail("all-caps acronym inside a camelCase identifier",
     sorted(i for i in idents if re.search(r"[a-z][A-Z]{2,}", i)))

# --- 5. unbalanced code fences ------------------------------------------------
fence = sum(1 for l in lines if l.strip().startswith("```"))
fail("unbalanced code fences", [] if fence % 2 == 0 else [f"{fence} fences"])

# --- 6. emphasis or code markers split across a line break --------------------
split = []
for i, l in enumerate(lines[:-1]):
    if re.search(r"(?<!\*)\*$", l) and lines[i + 1].startswith("*"):
        split.append(f"{i+1}: bold split -- {l[-38:]!r} / {lines[i+1][:38]!r}")
prose = re.sub(r"```.*?```", "", src, flags=re.S)
for para in prose.split("\n\n"):
    if para.count("`") % 2:
        split.append(f"unclosed code span -- {' '.join(para.split())[:72]!r}")
fail("marker split or unclosed span", split)

# --- 7. table rows whose column count differs from their header ---------------
bad, hdr, hdr_ln = [], None, 0
for i, l in enumerate(lines, 1):
    if l.startswith("|"):
        n = l.replace("\\|", "").count("|")
        if hdr is None:
            hdr, hdr_ln = n, i
        elif n != hdr and not set(l) <= set("|-: "):
            bad.append(f"{i}: {n} pipes vs header {hdr} at {hdr_ln}")
    else:
        hdr = None
fail("table row column mismatch", bad)

# --- 8. Entity.field references that resolve to no such field -----------------
tables = {}
cur = None
for l in lines:
    m = re.match(r"^#{3,4} [\d.]+ (\w+)", l)
    if m:
        cur = m.group(1)
    if l.startswith("| `") and cur:
        f = re.match(r"^\| `([A-Za-z][A-Za-z0-9_]*)`", l)
        if f:
            tables.setdefault(cur, set()).add(f.group(1))
unresolved = []
for ent, fld in set(re.findall(r"`([A-Z][A-Za-z]+)\.([a-z][A-Za-z0-9_]*)`", src)):
    if ent in tables and fld not in tables[ent]:
        unresolved.append(f"{ent}.{fld}")
note("Entity.field refs not found in that entity's table", sorted(unresolved))

# --- 8b. TaxYear data with no consumer ----------------------------------------
# A rate or threshold that no formula reads is a cost the engine never charges.
ty = re.search(r"### 3\.12 TaxYear(.*?)\n### 3\.13", src, re.S)
if ty:
    declared = set(re.findall(r"^- `([A-Za-z][A-Za-z0-9_]*)", ty.group(1), re.M))
    outside = src[:ty.start()] + src[ty.end():]
    # §7.4's table only restates the indexed flag; it is not a consumer
    outside = re.sub(r"### 7\.4 Non-indexed thresholds.*?\n### 7\.5", "", outside, flags=re.S)
    fail("TaxYear datum with no consumer outside §3.12",
         sorted(d for d in declared if d not in outside))
    note("TaxYear data declared", [f"{len(declared)} total"])

# --- 8c. entity fields declared but never read --------------------------------
# Same shape as 8b: a field nothing consumes is a promise the engine never keeps.
declared_f = {}
cur = None
INERT = re.compile(r"[Dd]isplay only|reporting only|never in tax|Recorded so|Warning only"
                   r"|read by no engine|Read by no engine|no engine (rule|calculation)")
for l in lines:
    m = re.match(r"^#{3,4} ([\d.]+) (.+)", l)
    if m:
        cur = m.group(2).strip()
    f = re.match(r"^\| `([A-Za-z][A-Za-z0-9_]*)`\s*\|[^|]*\|(.*)$", l)
    if f and cur and not INERT.search(f.group(2)):
        declared_f.setdefault(f.group(1), cur)
# Entities declared as prose lists ("**AssetClass:** `id`, `label`, ...") are invisible to
# the table parser above, and their fields have repeatedly gone unnamed at their use sites.
for m in re.finditer(r"\*\*(\w+):?\*\*:?\s*`id`([^\n]*(?:\n(?!\n)[^\n]*)*)", src):
    ent, rest = m.group(1), m.group(2)
    rest = re.sub(r"\([^)]*\)", "", rest)      # drop enum-value lists, which are not fields
    for f in re.findall(r"`([a-z][A-Za-z0-9_]*)`", rest):
        declared_f.setdefault(f, ent + " (prose)")

GENERIC = {"id", "label", "amount", "value", "kind", "mode", "balance", "year",
           "displayName", "socialSecurity", "employerMatch", "trigger",
           "currentValue", "currentBalance", "startYear", "endYear", "stopYear",
           "personId", "householdId", "taxUnitId", "categoryId", "scenarioId"}
unread = []
for f, sec in sorted(declared_f.items()):
    if f in GENERIC:
        continue
    if len(re.findall(r"\b" + re.escape(f) + r"\b", src)) < 2:
        unread.append(f"{f}  ({sec})")
fail("entity field declared but never referenced again", unread)

# --- 8d. a ?? fallback whose primary is not nullable ---------------------------
# A non-nullable primary makes the fallback dead code and its default unreachable.
types = {}
for l in lines:
    m = re.match(r"^\| `([A-Za-z][A-Za-z0-9_]*)`\s*\|\s*([A-Za-z][A-Za-z0-9_?\[\]]*)\s*\|", l)
    if m:
        types.setdefault(m.group(1), m.group(2))
dead = []
for m in re.finditer(r"([A-Za-z][A-Za-z0-9_.]*)\s*\?\?", src):
    name = m.group(1).split(".")[-1]
    t = types.get(name)
    if t and not t.endswith("?"):
        dead.append(f"{name}: declared {t}, so the ?? beside it never fires")
fail("?? fallback whose primary cannot be null", sorted(set(dead)))

# --- 10. a sum inside a per-X section that never names X ----------------------
SCOPED = ("this TaxUnit", "over persons", "over taxUnits", "over TaxUnits", "over covered",
          "those same accounts", "over streams", "active this year", "already paid off",
          "that no account absorbed", "this year (§8.4)", "this Person", "owned by that Person",
          "over taxable Accounts", "over taxDeferred", "over the household's")
unscoped = []
for sec in ("4.3", "4.4", "8.2", "8.4"):
    m = re.search(r"### " + sec.replace(".", r"\.") + r" (.+?)\n(.*?)(?=\n### |\n## )", src, re.S)
    if not m:
        continue
    for l in m.group(2).split("\n"):
        if "Σ" in l and not any(k in l for k in SCOPED):
            unscoped.append(f"§{sec}: {' '.join(l.split())[:80]}")
fail("sum inside a per-X section that never names X", unscoped)

# --- 11. TaxYear.X / Assumptions.X referenced but declared nowhere -------------
for owner, pat in (("TaxYear", r"### 3\.12 TaxYear(.*?)\n### 3\.13"),
                   ("Assumptions", r"\*\*Assumptions\*\* \(per `Scenario`\):(.*?)\n### 3\.10")):
    d = re.search(pat, src, re.S)
    if d:
        decl = set(re.findall(r"[A-Za-z][A-Za-z0-9_]*", d.group(1)))
        used = set(re.findall(owner + r"\.([A-Za-z][A-Za-z0-9_]*)", src))
        fail(f"{owner}.X referenced but declared nowhere", sorted(used - decl))

# --- 12. a limitFamily no waterfall step can fund ------------------------------
li = [i for i, l in enumerate(lines) if l.startswith("| `limitFamily`") and "Kinds" in l]
if li:
    fams = []
    for l in lines[li[0] + 2:]:
        m = re.match(r"^\| `(\w+)`", l)
        if not m:
            break
        fams.append(m.group(1))
    steps = " ".join(re.findall(r"^\d+\. `(\w+)`", src, re.M))
    HINT = {"electiveDeferral": "electiveDeferral", "simpleDeferral": "electiveDeferral",
            "ira": "iraToLimit", "hsa": "hsa", "none": "taxableBrokerage"}
    orphan = [f for f in fams if HINT.get(f, f) not in steps and f not in src.split("have no step")[0][-400:]]
    note("limitFamily with no waterfall step (documented as committed-only?)", orphan)

# --- 13. an entity in the §2 tree missing from §11's export list ---------------
tr = re.search(r"## 2\. Entity overview\n\n```\n(.*?)```", src, re.S)
ex = re.search(r"\*\*Export\*\* produces(.*?)An explicit schema version", src, re.S)
if tr and ex:
    ents = set(re.findall(r"([A-Z][A-Za-z]+) \(", tr.group(1)))
    body = ex.group(1).lower()
    NEVER = {"TaxYear"}                      # bundled, deliberately not exported
    EMBED = {"SocialSecurityBenefit"}        # travels inside its Person
    missing = []
    for e in sorted(ents - NEVER - EMBED):
        words = re.sub(r"([a-z])([A-Z])", r"\1 \2", e).lower().split()
        if not any(w.rstrip("y") in body or w + "s" in body for w in words):
            missing.append(e)
    fail("entity in the §2 tree with no counterpart in §11's export list", missing)

# --- 14. a flag with no stated engine consequence ------------------------------
if fl:
    VERB = re.compile(r"cap\b|capped|skip|stops?\b|zero|does not qualify|falls back|keeps the|"
                      r"sourced|drawn|draws|accepts?|pays|applies|reinvest|deleted|not unwound|"
                      r"warns|do not block|not a block|breach|reduces no|contributes nothing|"
                      r"wins\b|keeps? the|does not size|falls back|is deleted|stays |"
                      r"moves each|carries|drops|is raised|erring|overriding")
    silent = []
    for f in FLAGS:
        # whole paragraph, not sentence: §-refs contain periods and split it wrongly
        ctx = [p for p in src.split("\n\n") if re.search(r"\b" + f + r"\b", p)
               and "flags[]" not in p]
        if ctx and not any(VERB.search(c) for c in ctx):
            silent.append(f)
    fail("flag that warns without stating what the engine does", silent)

# --- 15. an invariant cross-reference pointing at the wrong invariant ----------
# Renumbering shifts these silently, and a wrong one still points at a real rule.
iv = re.search(r"## 12\. Invariants(.*?)\n## 13\. Deferred", src, re.S)
if iv:
    # full body of each invariant, not just its first line
    parts = re.split(r"\n(?=\d+\. )", iv.group(1))
    items = {}
    for part in parts:
        m = re.match(r"(\d+)\. (.*)", part, re.S)
        if m:
            items[int(m.group(1))] = " ".join(m.group(2).split())
    body = src[:src.index("## 12. Invariants")] + src[src.index("\n## 13. Deferred"):]
    # each reference, with the subject it is cited next to
    CUES = {"plannedSaleYear": "saleProceedsAccountId", "outflows": "accountId",
            "securedByLiabilityId": "securedAssetId", "categoryId": "ExpenseCategory",
            "counted twice": "counted twice", "ExpenseItem": "ExpenseItem",
            "claimingAge": "claimingAge", "TaxUnit`s": "personId"}
    bad = []
    for m in re.finditer(r"([^.\n]{0,80})\(?invariants? (\d+)(?: and (\d+))?\)?", body):
        ctx = m.group(1)
        for g in (m.group(2), m.group(3)):
            if not g:
                continue
            n = int(g)
            if n not in items:
                bad.append(f"invariant {n} does not exist -- {' '.join(ctx.split())[-50:]}")
                continue
            for cue, want in CUES.items():
                if cue in ctx and want not in items[n]:
                    bad.append(f"invariant {n} cited beside '{cue}' but says: "
                               f"{' '.join(items[n].split())[:46]}")
    fail("invariant cross-reference pointing at the wrong rule", sorted(set(bad)))
    note("invariant cross-references checked",
         [f"{len(re.findall(r'invariants? [0-9]+', body))} references, 1..{max(items)}"])

# --- 9. identifiers appearing exactly once (informational) --------------------
once = sorted(i for i in idents
              if len(src.split(f"`{i}`")) - 1 == 1 and re.search(r"[a-z][A-Z]", i))
note("camelCase identifiers appearing exactly once", once)

# --- 17. a field table with nothing naming the entity it belongs to -----------
# EmployerMatch sat unlabelled between an IRA paragraph and a formula block, and
# the `See below.` pointing at it had nothing to land on.  A heading or a bold
# name must appear within five lines above any `| Field |` header row.
LABEL = re.compile(r"^(#{3,4} |\*\*[A-Z][A-Za-z]*(\*\*|:))|:$")
unlabelled = []
for i, l in enumerate(lines):
    if not re.match(r"^\| Field\s*\|", l):
        continue
    if not any(LABEL.match(lines[j].strip())
               for j in range(i - 1, max(-1, i - 6), -1) if lines[j].strip()):
        unlabelled.append(f"line {i+1}: table under {lines[max(0,i-2)].strip()[:52]!r}")
fail("field table with no entity name above it", unlabelled)

# --- 18. a statutory number written into a formula instead of TaxYear ---------
# §3.12 promises every statutory rate and threshold is data, with 59 1/2 and 65
# named as the two exceptions.  These are the numbers a formula may still carry:
#   0 1 2   arithmetic identities and halves (the mid-year convention's frac / 2)
#   3       the fixed-point pass cap in §4.4.3, an engine bound and not a rate
#   11 12   month indices and counts
#   100     percent conversion in fplPercent
#   65      the age exception §3.12 states
blocks = re.findall(r"```(.*?)```", src, re.S)
STRUCTURAL = {"0", "1", "2", "3", "11", "12", "100", "65"}
literals = []
for b in blocks:
    for line in b.split("\n"):
        code = re.sub(r"//.*", "", line)
        code = re.sub(r"§\d+(\.\d+)*", "", code)          # section refs are not values
        for m in re.finditer(r"(?<![\w.\[/])(\d+\.\d+|\d+)(?![\w.\]/])", code):
            if m.group(1) in STRUCTURAL:
                continue
            literals.append(f"{m.group(1)}  in  {' '.join(code.split())[:64]}")
fail("statutory number in a formula rather than TaxYear (§3.12)",
     sorted(dict.fromkeys(literals)))

# --- report -------------------------------------------------------------------
for label, items in fails:
    print(f"FAIL  {label}")
    for it in items:
        print(f"        {it}")
for label, items in notes:
    print(f"note  {label}: {len(items) if len(items) > 3 else ''}")
    for it in items[:40]:
        print(f"        {it}")
print()
print("PASS 0 CLEAN" if not fails else f"PASS 0: {len(fails)} check(s) failed")
sys.exit(1 if fails else 0)
