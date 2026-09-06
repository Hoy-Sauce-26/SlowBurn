# Domain Model Review Plan

A staged review of [`domain.md`](domain.md). Current scope: 13 sections, 14 entities, 24
invariants, 36 formula blocks, ~21k words.

## Why this exists

This plan replaces linear reading with **cross-cutting passes**. Each pass applies one
lens to the whole document and finishes. The lenses come from the defects already found,
grouped by how they hid rather than by what they were about.

## What the four reviews found

| Failure mode                                 | Instance                                                                                                        | How it hid                                                                                                    |
|----------------------------------------------|-----------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------|
| Missing term in an identity                  | `OneTimeEvent` never appeared in `netSurplus`                                                                   | §3.8 promised the behavior in prose, §4.4's formula never implemented it, and neither section was wrong alone |
| Incomplete consumer set                      | Depreciation recapture reached `recaptureTax` but not `netInvestmentIncome`                                     | The quantity was correctly computed and correctly used once                                                   |
| Incomplete writer set                        | `costBasis` was not raised by `OneTimeEvent` deposits                                                           | §6 listed four writers, §3.5 added a fifth inline, §3.8 added a sixth nowhere                                 |
| Scope mismatch                               | Five sums in §4.3 reached across `TaxUnit`s                                                                     | The section header said "per TaxUnit" and the sums did not repeat it                                          |
| Unconstrained redundancy                     | `Household.personIds`, `TaxUnit.personIds`, `ExpenseItem.householdId`                                           | Each looked reasonable in its own table; nothing forced them to agree                                         |
| Type contradicts prose                       | `assetSaleCostRate`, one scalar documented as two values                                                        | §3.5 and §3.9 agreed with each other and not with the type                                                    |
| Prose promises what the model cannot express | 403(b) named twice, absent from `Account.kind`                                                                  | The prose was correct about tax law                                                                           |
| Universal rule applied incompletely          | "Every threshold carries an `indexed` flag", but the ACTC floor had none                                        | The rule and its exception sat 900 lines apart                                                                |
| Pattern inconsistency                        | `PayrollDeduction`'s flags were not overridable, unlike `IncomeStream.isFicaSubject` and `Account.taxTreatment` | Each entity read fine in isolation                                                                            |
| Missing lifecycle event                      | `Asset` had `plannedSaleYear` and no acquisition                                                                | An asymmetry is invisible unless you go looking for the mirror                                                |
| Two paths, one silently worse                | `OneTimeEvent.kind = homeSale` beside `Asset.plannedSaleYear`                                                   | A warning paragraph documented the trap instead of removing it                                                |
| Wrong authority, right effect                | `commuterBenefit` labelled §125 when it is §132(f)                                                              | The computed number was correct                                                                               |
| Claim contradicted by its own dependency     | §8.1 claimed "no tax solve" while depending on §8.2's tax-solving draw                                          | Both statements were local and plausible                                                                      |
| Counted claim outrun by the model            | "Three places need sub-annual behavior"; invariant 15's "Four mechanisms" after a fifth money path was added | The count was right when written, and nothing updates a number when a list grows elsewhere |
| Storage shape cannot hold the value's variability | `ProjectionSnapshot.fireNumber` typed `Money` where the quantity is per band, as `retirementYear` beside it already was | Nothing claimed otherwise; the type was simply wrong about reality, and its per-band neighbour made it look considered |
| Fix exposes a second site of its own mode    | Exempting year-0 point events from proration left `frac` still scaling `oneTimeNet` inside `netSurplus` | The fix reads complete at the site it was made; the same distinction lives one section away under a different name |
| Rule stated for spans, silent for points     | Year-0 proration covers `ExpenseItem`, `IncomeStream` and `PayrollDeduction` ranges; `OneTimeEvent`, `acquisitionYear` and `plannedSaleYear` fire again on top of balances that already include them | The proration paragraph reads complete because every entity it names is handled; the ones it does not name are invisible |
| Unreachable configuration                    | `sep` and `education` have no waterfall step, so a deductible SEP stays open while surplus goes to `taxableBrokerage` | The step list looks exhaustive on its own; only mapping it against `limitFamily` shows the two with no route |
| Sentinel value handled at some consumers only | `notReachable` was typed into §3.13 and handled in §8.2 and §10.2, while §3.1 and §9.3 both derive from a solved retirement year and said nothing | Introducing a sentinel feels finished once its own type and its headline consumer are updated |
| Optimistic deferral with no flag             | The retirement earnings test made the engine overpay pre-FRA benefits with only blanket UI prose, where QBI and vesting each raise one | Blanket disclosure looks like coverage; only sorting deferrals by direction shows which ones need a per-year signal |
| Approximation whose direction is undisclosed | The ACA-to-Medicare swap takes the whole year a person turns 65, understating that year, where 59½ two sections away states its rounding and why | The document discloses direction everywhere else, so a silent one reads as having none |
| Ordering stated against the wrong boundary   | Sweep 1's payroll elections were documented as running "before §4.3", but `hsaPayrollToLimit` reduces FICA wages, which §4.1 computes | "Before §4.3" is true, just not sufficient; a correct statement that names too late a boundary reads as settled |
| Reader positioned where its input is stale   | Basis maintenance runs after growth in §6's loop, so `outflow / balance` divided by a balance the draw never saw | The formula is right and the loop is right; only their relative position is wrong |
| Dependency on state nothing emits            | §3.4 reads prior-year `ficaWages` from `YearResult`, which did not carry it, while claiming it needs no new input | The reader and the emitter were both plausible; only reading them together shows the gap |
| Field scoped wider than the computation reading it | `acaBenchmarkPremiumOverride` sat on per-Scenario `Assumptions` while §4.3 read it per `TaxUnit`, so two TaxUnits priced off one premium | Its own Notes said "covering the whole `TaxUnit`", which read as a description rather than as a scope it did not have |
| Derived from the wrong axis                  | `isRestrictedPurpose` keyed on `kind` while `taxTreatment` is the axis a custom account may set, letting a custom education account count as liquid and be undrawable | Both derive from `kind`, so they look like siblings until one becomes overridable |
| Deferral silent about its direction          | `AMT` and `Long-term care cost modeling` were bare list entries where most §13 entries name the way they move a number | A list reads as uniform, so entries carrying extra detail look generous rather than making the bare ones look incomplete |
| Siblings that disagree on overridability     | `limitFamily` fixed beside an overridable `taxTreatment`; `reducesStateTaxableIncome` fixed beside its two overridable flags | The overridable ones read as the rule and the fixed one is invisible until the set is listed together |
| Table indexed past its last published row   | `federalPovertyLevel[state][size]` for a family of nine, `rmdDivisorTable` past 120; `socialSecurityFraByBirthYear` states a floor and the others said nothing | A lookup reads as total, and the one table that does state its range makes the silence of the rest look intentional |
| No sign constraint on a quantity            | Nothing forbade negative `Money`, so a negative `Contribution.value` passed `min(uncapped, familyCap)` unfloored and acted as a withdrawal skipping `withdrawalOrder` | Rates are legitimately negative in four places, which makes the absence of a sign rule look deliberate rather than missing |
| Guard covers one side of a reachable range   | `ficaWages` unfloored, so §125 deductions exceeding part-time pay ran `oasdi` and `medicare` negative; `claimingAge`'s 62–70 range stated in a note and enforced nowhere | Each guard is correct about the side it covers, and the other side only shows up on an input nobody pictured |
| Fallback whose primary cannot be null        | `ExpenseItem.relativeInflationRate` typed `Rate`, making its `??` dead and `defaultRelativeInflation` unreachable | The formula and the type each read correctly alone; only together does the `??` turn out to be unreachable |
| Override and its fallback behave differently | An empty `covered` set makes the fallback sum to zero; the override still charged in full | The `??` reads as one value with two sources, hiding that only one of them handles the empty case |
| Same name, two scopes                        | `rmdIncome` defined per `TaxUnit` in §4.3 and household-wide in §8.4, consumed as both | Each definition was correct where it stood; `ssBenefits` two lines away shows the right form |
| Marker or qualifier with ambiguous scope     | `(fixed)` placed after a colon ending a list containing a *rate*, so `niitRate` read as deflatable | The marker was right and the datum it belonged to was right; only the attachment was loose |
| Declared cost with no consumer               | The 10% early-withdrawal and 20% HSA penalties were `TaxYear` rates read by no formula | A conservation trace follows movements, and this was a rate that never became one |
| Required input with no default               | `generalInflationRate` and `capitalGainsRealizationRate` | The document reads complete; the gap is only visible against the fields that do state one |
| Drift and dangling                           | `ProjectionResult` undefined, six acronym-casing outliers, a `**reverts**` split across a line break            | Invisible to reading, trivial to script                                                                       |

Three patterns account for most of it: a rule stated next to one caller instead of next to
the state it governs; a set enumerated in one place and extended in another; and an
asymmetry nobody had reason to look for.

## Passes

Ordered so each one operates on content the previous has stabilized.

**The lenses are now encoded, so a run is one command rather than an act of invention.**
Twenty-three runs each turned on thinking up the right lens; that is not repeatable and it is
what made the yield depend on the reviewer. Four scripts hold them:

- `scripts/check.py` — the entry point. Runs the three below and prints one verdict, `PASS`
  or `FAIL`, exiting 1 on a fail. Only the gate decides it; the other two say what to read.
  `--quiet` prints the verdict alone.
- `scripts/check-domain.py` — 20 hard checks. Exit 1 on anything a script can prove wrong.
  Run after every edit. Four came from decisions the document made later: a `| Field |`
  table with no entity name above it, a statutory number written into a formula instead of
  `TaxYear` (§3.12), an entity section declaring its fields outside a table, and a field
  discussed in an entity section but declared in no table. All are silent when clean, so
  none is a lens. The last two exist because that defect appeared four separate times:
  `Person.retirementYear`, `Liability.principalAndInterest`, the `Scenario` entity, and an
  `originationDate` / `termMonths` row carrying two fields at once.
- `scripts/lenses.py` — 14 survey lenses over the categories where defects actually turned
  up: counted claims, one-sided guards, divisions, `??` fallbacks, age thresholds,
  span-versus-point rules, dichotomies, sentinels, deferral direction, UI obligations, field
  scope, ordering, table lookups, derivation axes. It always exits 0; reading the output is the work.
- `scripts/sweep-consumers.py` — run on every identifier a change touches, before calling
  the change done.

A run is: gate, survey, triage, fix, sweep, gate again. `scripts/check.py` is the first and
last step of it.

## When this is finished

**The suite is frozen at 18 checks and 14 lenses.** New lens ideas go in a backlog, not here
and not into the scripts. The lens space is unbounded, so a run can always be made to find
something by widening what counts; twenty-eight runs did exactly that, growing this taxonomy
from 14 modes to 38 while the document was getting better. That is not measurement.

**Done means: the gate is green, and a run turns up nothing that changes a number for a
household using the app normally.** Sorting all findings by that test:

| runs | what the findings were |
|---|---|
| 1–23 | ordinary input, wrong number: penalties never charged, basis cut 67% instead of 40%, two tax rates deflated, sums crossing `TaxUnit` boundaries |
| 24–28 | malformed input a UI would reject, hand-built custom accounts, and prose consistency |

That criterion was met at run 23 and has held for five runs since. Robustness against
malformed input and editorial polish are real work, but they are a ratchet with no top, and
they do not belong in the same queue as a wrong retirement date.

**Word count is part of the standard.** Every fix should hold it or reduce it, and rationale
for a defect that no longer exists is the first thing to cut.

### Pass 0 — Mechanical integrity *(scripted, continuous)*

**Lens:** things a script can prove.
**Method:** identifiers appearing exactly once; flags in §6's `flags[]` with no definition
elsewhere; every `§n.n` cross-reference resolving to a real heading; invariant numbering
sequential; all-caps acronyms inside camelCase identifiers; unbalanced code fences; bold or
code markers split across line breaks; table rows whose column count differs from their
header; every `TaxYear` rate and threshold with no consumer outside §3.12, since a cost the
engine never charges is invisible to every other pass; and the mirror of that in both
directions, every `TaxYear.X` and `Assumptions.X` referenced in a formula but declared
nowhere, and every entity field declared but never read.
**Done when:** every check returns empty.

### Pass 1 — Ownership and scope

**Lens:** what belongs to what, and what each computation is scoped to.
**Method:** tabulate every entity's owner link and confirm exactly one, with any second path
covered by an invariant. Then, for every section headed "per X", check that each `Σ` names
the X it sums within. Then check every aggregate measure (§5) honors the lifecycle gates
stated elsewhere.
**Done when:** the owner table has one entry per entity and no unscoped `Σ` remains inside a
scoped section.

### Pass 2 — State lifecycle

**Lens:** engine-maintained state and everything that writes it.
**Method:** for each of `costBasis`, `rothContributionBasis`, `accumulatedDepreciation`,
`balance`, `currentBalance`, `currentValue`, and the two-year MAGI history, enumerate every
writer in the document and confirm the field's own maintenance rule names all of them.
Enumerate every reader and confirm each reads a value that is current at that point in §6's
loop.
**Done when:** each piece of state has one maintenance rule listing every writer.

### Pass 3 — Follow the money

**Lens:** conservation.
**Method:** trace every dollar that can enter or leave the household — earned income,
distributions, employer match, one-time events, asset sales, loan proceeds, withdrawals,
taxes, expenses, debt service — and confirm each appears in exactly one term of `grossIncome`
or `netSurplus`, or moves between balances without touching either. Double-counted and
vanished dollars are the same check from opposite ends.
**Done when:** every path is accounted for once.

### Pass 4 — Symmetry and analogy

**Lens:** things that should mirror each other.
**Method:** diff sibling entities against each other (`Contribution` vs `PayrollDeduction`,
`Asset` vs `Account`, the three `reduces*` flag sets) and mirrored operations against their
opposites (purchase/sale, contribution/withdrawal, accrual/recapture, claim/repay). A field
or rule present on one side and absent on the other is either a finding or a decision worth
recording.
**Done when:** every asymmetry is deliberate and stated.

### Pass 5 — Type versus prose

**Lens:** whether each field can hold what its documentation claims.
**Method:** for every field, check the type supports every claim in its Notes, including
nullability and cardinality. For every enum, check each value is reachable and each value
named in prose exists in the enum. For every formula, check the surrounding prose describes
what it computes.
**Done when:** no Notes cell asserts behavior its type cannot carry.

### Pass 6 — Universal claims

**Lens:** sentences containing "every", "always", "never", "only", "the one", "exactly".
**Method:** extract them and verify each exhaustively rather than by recall. These are the
document's strongest statements and its most load-bearing, which is why an unnoticed
exception is expensive.
**Done when:** each claim is verified, narrowed, or dropped.

### Pass 7 — Footguns

**Lens:** places a reasonable user or implementer will go wrong.
**Method:** find every operation expressible two ways and confirm the model prefers one or
constrains both. Find every field whose documentation warns against its obvious use. Find
every default that silently produces a wrong answer rather than an obviously wrong one.
Prefer removing the trap over documenting it.
**Done when:** no field's Notes exist mainly to prevent misuse of that field.

### Pass 8 — Tax-law verification

**Lens:** the statute, not the model's internal consistency.
**Method:** take each computation in §4.2, §4.3, §8.4 and the `TaxYear` schema and check the
rule, the threshold, the filing-status variation, and the authority cited. Every prior pass
checks the model against itself; this is the only one that checks it against the world.
**Done when:** each computation is confirmed or its simplification is recorded in §13.

### Pass 9 — Density

**Lens:** argument that has outlived its rule.
**Method:** section by section, in descending word count. Cut worked examples that teach
nothing an implementer lacks, product reasoning about when to prompt, editorializing after
the mechanism is stated, defaults repeated from the section that owns them, and paragraph
pairs that say one thing twice. Keep every rule, formula, threshold, flag, and default.
**Done when:** each section is one rule per paragraph with at most one clause of why.

Run last. Density work on content that is still moving wastes the effort, and §3.6 and §3.4
both showed the yield depends entirely on whether the prose has already been disciplined.

## Recording results

Log findings against the pass that found them and the failure mode from the table above. A
pass that finds a defect the table does not describe means the taxonomy is incomplete, and
that is worth more than the defect.

**Grep every counted claim** ("three places", "four mechanisms", "two things") and
re-count it. These drift silently whenever a list grows in another section.

**Check that each stored quantity's type can hold its actual variability** — per band, per
person, per year. A scalar beside a per-band sibling is the tell.

**§11's export list is an enumeration of the entity inventory and drifts with it.** Re-derive
it from §2's tree each run.

**After fixing one instance of a mode, grep for the same distinction under other names.**
Run 22 exempted point events from proration; `frac` was scaling them one section later.

**Map every fixed vocabulary against the thing it is meant to cover**, and check every rule
written for spans covers point events too. `WaterfallStep` against `limitFamily` left two
families unreachable; year-0 proration named three span entities and no point ones.

**Every sentinel needs sweeping like a field.** `notReachable`, `alreadyCoasting`, and any
successor: find each place that derives from the quantity the sentinel replaces, not just the
places that store or report it.

**Sort every §13 deferral by whether it makes the model optimistic or conservative.** An
optimistic one whose condition the engine can detect needs a flag, the way `qbiLimitNotModeled`
and `unvestedMatchAtRisk` do; a conservative one does not. Blanket UI prose is not the same
thing and reads as coverage.

**List every threshold the engine tests an age or a date against, and check each states its
rounding direction.** 59½ does; 65 did not. Where an approximation is deliberate the
document says which way it errs, so a silent one is a gap rather than a choice.

**Check the pipeline runs in the order its sections are numbered, and where it does not,
that the exception names the earliest boundary it needs.** §4 opens with "Order matters" and
then defines sweep 1 inside §4.4 while §4.1 depends on it.

**Audit every division for a zero denominator, and every unit conversion for its factor.**
`safeWithdrawalRate` is a denominator twice in §8.1 and the annuity is a third, zero at
`N = 0`; nothing bounded either. Entity rates carry bounds (invariants 7, 14, 26) and
`Assumptions` rates carried none, which is where to look first.

**Audit every `min`, `max`, `clamp` and range note for the side it does not cover.** A
floor with no ceiling, a ceiling with no floor, or a documented range enforced by no
invariant. Ask what input reaches the uncovered side, not whether one is likely.

**Audit every `??` from both sides.** Check the primary is actually nullable, or the
fallback is dead; check the fallback and the primary agree on the empty case; check the
chain terminates in something non-null. Now scripted in Pass 0 for the first of the three.

**Test every stated dichotomy for a third case, and every cascade for the level it skips.**
"A `Scenario` varies `Assumptions` only; differing data means a cloned `Household`" read as
exhaustive and was not: band return rates live on `AssetClass` and neither route reaches
them. Invariant 6 specified Scenario→Snapshot deletion and not Household→Scenario.

**A known-accepted list beats re-triaging.** Eleven nullable fields define null in prose or
by mode rather than in their Notes cell; they resurface in Pass 5 every run. Record the
triage once instead of redoing it.

**Entities declared in prose escape every table-based check.** `ExpenseCategory`,
`AssetClass`, `Scenario`, and `YearResult` are declared as prose lists, so the field,
type, and consumer checks had never seen them. Audit them by hand each run.

**Apply each pass's lens to the document's own apparatus, not just its prose.** §12's
invariants are universal claims and had never faced Pass 6; doing so found two stated
absolutely with an unacknowledged exception, where a third names its exception correctly.
The same applies to §13's deferrals, §3.12's markers, and the flag list.

**Sweep the consumers of anything you change, before calling the change done.** Six of the
nine defects this session's own edits introduced were one mistake: a field added, removed,
or redefined while some consumer elsewhere went stale. `scripts/sweep-consumers.py` takes
an identifier, or `--diff` for everything the working diff touches, and lists every
reference grouped by section, then names the places that do *not* mention it. The §2 tree,
§5's measures, §6's loop, §9's variants, §10's snapshot trigger, §11's export list and
§12's invariants are where the stale ones actually hid.

**Verify that each fix landed, separately from making it.** A re-run of the plan found two
fixes reported as applied that were not: the edit script asserted before it wrote, so a
failed assertion discarded the whole batch silently. Grep for each intended change after a
pass, not just for the defect it addressed.

| Pass                   | Status | Findings | Notes |
|------------------------|--------|----------|-------|
| 0 Mechanical           | re-run clean | 2        | Scripted as `scripts/check-domain.py`; run after every edit. Found `escrowDiffersFromInferred` orphaned by a §3.6 trim, and "Escrow is *only ever* inferred" contradicting the `??` two lines below it. |
| 1 Ownership and scope  | run 13: +1   | 8        | Owner links clean. 8 more unscoped `Σ` in §4.3, all over person-owned entities, so the earlier fix had caught the instances and not the class. §4.4 had no scope declaration. Cross-links constrained for presence but not membership (invariant 25). `retirementYear` absent from §5's index. |
| 2 State lifecycle      | run 22: +1   | 10        | `rothContributionBasis` credited on a `traditional401k` that has no such field, and its rollover writer unnamed. `Liability.currentBalance` had no maintenance rule, so the `highInterestDebt` paydown was a writer known only to §4.4. §6 grew Assets not yet acquired. `Asset.costBasis` static vs `Account.costBasis` maintained. |
| 3 Follow the money     | run 23: +1   | 6        | The 10% early-withdrawal and 20% HSA non-medical penalties existed as `TaxYear` rates and prose in three places but reached no cash-flow term, pricing the bridge as free. A `Liability` originating mid-projection had no home for its proceeds unless it financed an `Asset`. |
| 4 Symmetry and analogy | run 27: +2   | 6        | `Contribution` had `stopYear` and no `startYear`, unlike `PayrollDeduction` and `IncomeStream`, so a `fixedAmount` contribution ran from year 0 with no income behind it. Invariant 23 extended to committed contributions. |
| 5 Type versus prose    | run 26: +1   | 10        | `rothFirstContributionYear` null semantics undefined while gating `rothEarnings` qualification and the bridge test. `Liability.securedAssetId` had an empty Notes cell. Enums all reachable; conditional-required types correct. |
| 6 Universal claims     | run 12: +1   | 7        | 178 candidates; §1.1's "every rate is **real**" is contradicted by `Liability.interestRate` (nominal by design) and `generalInflationRate`. Narrowed to what is true, naming both exceptions. |
| 7 Footguns             | run 28: +1   | 9        | `generalInflationRate` and `capitalGainsRealizationRate` had no defaults despite deflating thresholds and driving tax drag. `OneTimeEvent` purchase vs `Asset` acquisition left undocumented, unlike the sale case. |
| 8 Tax-law verification | run 25: +1   | 3        | All ten hard-coded constants correct against statute. Unrecaptured §1250 modeled as flat 25% where statute caps at the lesser of 25% and marginal; simplification now recorded in §13. |
| 9 Density              | re-run clean | -        | §8.1 1118 -> 1040 prose words. Yield is low now: after §3.6 and §3.4, remaining sections are near their floor, each paragraph carrying a distinct rule. |
