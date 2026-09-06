# Slow Burn Domain Model

Slow Burn is a FIRE calculator that is free, private (nothing leaves the device), and
fits your life. It models a household's income, taxes, savings, assets, liabilities,
and expenses, then projects them forward to answer one question: **when can you stop
working?**

This document defines the domain: the entities, their fields, the derived quantities,
the order in which they are computed, and the invariants that must hold. It is the
reference the calculation engine and the UI are both written against.

---

## 1. Foundational modeling decisions

### 1.1 All money is in today's dollars

Every stored amount and every projected figure is **real**, expressed in present-day
purchasing power, and so is every rate the engine applies to them. Two rates are not, and
each says so where it is declared: `Liability.interestRate` is nominal because a lender
fixes the schedule in nominal terms (§3.6), and `generalInflationRate` is the conversion
between the two (§3.9).

- Asset appreciation rates are **real returns**: a user entering 5% for stocks means 5%
  above inflation.
- Income growth is a **real** raise rate, where 0% keeps pace with inflation.
- Expenses stay flat year over year by default, since they already sit in today's dollars. A
  per-expense **relative** inflation rate captures categories that outpace general
  inflation, such as healthcare at +2.5% real.
- Tax brackets are treated as inflation-indexed and held constant in real terms.
  Thresholds that statute never adjusts are explicitly deflated each projected year.
  Which are which is recorded on the data (§3.12, §7.4).

Real dollars throughout make the safe-withdrawal-rate input mean what users think it
means, and make "you retire in 14 years" legible without mentally deflating a number.

A **nominal display toggle** may inflate outputs for presentation while the engine stays
real-only. `Assumptions.generalInflationRate` is stored to support that toggle and to
convert user-entered nominal rates on input.

### 1.2 Annual granularity

The projection engine steps in **whole years**, and sub-annual behavior such as paycheck
timing is modeled as an annual aggregate. Expenses and contributions may be *entered* at
any frequency and are normalized to annual on save.

Sub-annual behavior appears wherever an annual step would be visibly wrong, and every case
is closed-form rather than a shortened step: the cash buffer's fill-to-target rule (§4.4.4),
the mid-year convention on the year's flows (§6.2), the 59½ and Social Security claiming dates
resolved to whole-year gates (§3.1, §3.11), and the Coast FIRE date interpolated within its
crossing year (§9.3).

Every projection run also has an `asOfDate`, and its first year is prorated to the remaining
fraction of that calendar year (§6), so a run in August prices the remaining
months correctly.

### 1.3 United States only

FICA, Medicare, state income tax, 401(k)/HSA/IRA account kinds, ACA subsidies, and
Social Security are all US constructs and are modeled directly. Internationalization is
out of scope and should not be designed around.

### 1.4 Local-only storage

**Tax tables ship with the app.** There is no server to push a new tax year from, so a
new `TaxYear` ruleset requires an app update, and the engine must degrade gracefully
when the calendar year is newer than the newest bundled one (§7.5).

**No cross-device sync**, and no account recovery.

**Export / import is a first-class feature.** Device loss otherwise means total data
loss. See §11.

### 1.5 Deterministic projection with three return bands

Projections are deterministic and always run **three bands** (`pessimistic`, `expected`,
`optimistic`), each using the corresponding rate stored on every `AssetClass` (§3.9).
Results are always presented as a range, because a single point estimate presents one
long-run average as if it were a forecast and hides how sensitive the plan is to which
average actually shows up.

Each band applies one constant rate to every year, so it says nothing about *ordering*, and a market
crash the year after retiring is far more damaging than the same crash a decade in. Monte Carlo and
historical-sequence backtesting are deferred (§13.1).

---

## 2. Entity overview

```
Household
├── TaxUnit (1..n)                       - one tax return: filingStatus, state, locality,
│   │                                      dependents, itemized total (§3.2)
│   └── Person (1..n)                    - what caps, limits, and ages apply to (§3.1)
│       ├── IncomeStream (0..n)          - (§3.3)
│       ├── Account (0..n)               - balance + contribution (§3.4)
│       ├── PayrollDeduction (0..n)      - pre-tax money that isn't saved (FSA etc.) (§3.4.5)
│       └── SocialSecurityBenefit (0..1) - (§3.11)
├── Employer (0..n)                      - an optional source of IncomeStreams and Accounts (§3.3)
├── Asset (0..n)                         - non-account holdings (home, car) (§3.5)
├── Liability (0..n)                     - debts, optionally secured by an Asset (§3.6)
├── ExpenseCategory (0..n)               - a group that houses types of ExpenseItems (§3.7)
│   └── ExpenseItem (0..n)               - an recurring expense (§3.7)
├── OneTimeEvent (0..n)                  - windfalls and lumpy costs (§3.8)
└── Scenario (1..n)                      - a named set of Assumptions to project under (§3.10)
    └── ProjectionSnapshot (0..n)        - frozen output history for that scenario (§3.13)

AssetClass (return rates by class; ships with defaults the user edits, and exported, §3.9)
TaxYear (reference data, versioned, bundled with the app, and never exported, (§3.12)
```

---

## 3. Entities

### 3.1 Person

The unit that FICA caps, contribution limits, and age-gated account access apply to.

| Field                           | Type                          | Notes                                                                                                                                                                                                                                                                                                                                                                                    |
|---------------------------------|-------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                            | ID                            |                                                                                                                                                                                                                                                                                                                                                                                          |
| `displayName`                   | string                        |                                                                                                                                                                                                                                                                                                                                                                                          |
| `birthDate`                     | date                          | **Required.** Drives 59½ access, catch-up eligibility, Medicare and IRMAA at 65, Social Security claiming and FRA, RMD age.                                                                                                                                                                                                                                                              |
| `taxUnitId`                     | ID                            | Which filing entity this person belongs to.                                                                                                                                                                                                                                                                                                                                              |
| `plannedRetirementAge`          | int?                          | Optional. Fixes this person's retirement year rather than leaving §8.2 to solve for it. Set it for a hard target at any age, early or traditional (§9.4), and `spendingHeadroom` (§5) then says whether that target works. Null is the common case and the one the engine is built around. |
| `retirementYear`                | int \| `notReachable`         | **Derived**, and what the rest of the model keys off: `plannedRetirementAge` applied to `birthDate` where set, otherwise the household's solved year (§8.2). See below. |
| `hsaCoverage`                   | {fromYear: int, tier: enum}[] | Ordered timeline of `none` \| `self` \| `family`, each entry effective from `fromYear` until the next. One entry is the common case; a second expresses `family` → `self` when a child ages off the plan. Selects which HSA contribution limit applies, and whether one applies at all (§3.4.2).                                                                                         |
| `employerHealthCoverageEndYear` | int?                          | Last year this person is covered by an employer plan. **Defaults to the year before their `retirementYear`.** While covered they contribute no ACA benchmark premium and generate no premium tax credit (§4.3.5), and their premium is a `PayrollDeduction` (§3.4.5). Extend it for employer retiree coverage, or past the horizon for a Barista FIRE job that carries insurance (§9.2). |
| `socialSecurity`                | SocialSecurityBenefit?        | See §3.11.                                                                                                                                                                                                                                                                                                                                                                               |

**Age conventions:**

- **`age(year)` is the age attained during the projected year**, or `year −
  birthDate.year`. Statute uses it for catch-up eligibility, the RMD age, and
  Social Security claiming: you are "age 50" for catch-up purposes for the whole calendar
  year in which you turn 50.
- **59½ is computed from the date and rounded conservatively.** A person is 59½-eligible
  for a projected year only if `birthDate + 59 years 6 months` falls on or before January
  1 of that year. At annual granularity (§1.2) the alternative grants a full year of
  penalty-free access to someone who reaches the threshold in December, and erring toward
  the penalty is the safe direction for a bridge test (§8.3) that gates retirement.

Reference data keyed by birth *year* (`socialSecurityFraByBirthYear` and
`rmdAgeByBirthYear`) is looked up on `birthDate.year`.

The Social Security wage base cap, 401(k) deferral limits, IRA limits, HSA limits, and catch-up
contributions are all assessed per individual, and computing them on a household total gives wrong
answers. `Person.retirementYear` is derived: their `plannedRetirementAge` applied to `birthDate` if
set, otherwise the household's solved `retirementYear` (§8.2). Where that comes back
`notReachable`, the person has no retirement year and §6.1's baseline stands: earned streams,
committed contributions, and employer coverage run to the horizon, and `ExpenseItem.phase`
never flips.

### 3.2 Household and TaxUnit

**Household**: the pooled economic unit. Aggregates net worth, expenses, and
projections. Has no tax meaning, and reaches its people through its `TaxUnit`s.

| Field            | Type | Notes                                                                                                                                                                                                                                                                        |
|------------------|------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`             | ID   |                                                                                                                                                                                                                                                                              |
| `expenseSharing` | enum | How shared expenses are attributed in reporting, never in tax, expenses reaching no part of §4.3: `pooled` splits them evenly, `proportional` by each `TaxUnit`'s share of household after-tax income, recomputed annually. Read by no engine calculation. Default `pooled`. |

**TaxUnit**: one tax return.

| Field                      | Type        | Notes                                                                                                                                                                                                                                                                                                                                                                                                                   |
|----------------------------|-------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                       | ID          |                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `householdId`              | ID          | Owner.                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `filingStatus`             | enum        | `single`, `marriedFilingJointly`, `marriedFilingSeparately`, `headOfHousehold`, `qualifyingSurvivingSpouse`                                                                                                                                                                                                                                                                                                             |
| `stateCode`                | string      | Resident state or DC. Required even where no income tax is levied, since the ACA poverty line varies by state (§3.12).                                                                                                                                                                                                                                                                                                  |
| `localityCode`             | string?     | NYC, Philadelphia, Ohio municipality, Maryland county, etc.                                                                                                                                                                                                                                                                                                                                                             |
| `dependents`               | Dependent[] | `{birthDate: date, isStudent: bool, supportEndYear: int?}`. `supportEndYear` **defaults to the year the dependent turns 19, or 24 when `isStudent`**. A dependent is counted only in years `≤ supportEndYear`. Count of active dependents drives HoH qualification and ACA tax-family size; each `birthDate` drives Child Tax Credit qualification (§4.3.4, under age 17 at the end of the tax year) and its phase-out. |
| `benchmarkPremiumOverride` | Money?      | Annual, and this `TaxUnit`'s own second-lowest-cost-silver-plan premium, if known. Null falls back to the per-person `TaxYear.acaBenchmarkPremiumByAge` (§4.3.5). It sits here because §4.3.5 reads it per `TaxUnit`.                                                                                                                                                                                                   |
| `itemizedDeductionTotal`   | Money?      | A single entered annual figure, in today's dollars, held constant in real terms across projected years. When set and larger than the standard deduction, §4.3.2 uses it. Deriving it from mortgage interest, SALT, and charitable giving is deferred (§13.2).                                                                                                                                                           |

When a `TaxUnit`'s `filingStatus` is `headOfHousehold` in a year with no active
dependent, the engine falls back to `single` for that year and raises
**`filingStatusNoLongerQualifies`**. This is the one filing-status transition the
projection produces on its own; marriage, divorce, and death are deferred (§13.1).
`qualifyingSurvivingSpouse` is in the enum for a user already in that status, and the
engine never transitions a `TaxUnit` into it.

A household of two friends is one `Household` containing two `TaxUnit`s, each with one `Person`. A
married couple filing jointly is one `Household` with one `TaxUnit` containing two`Person`s. A
married couple filing jointly in a polyamorous relationship with one additional partner is one
`Household` with two `TaxUnits`, one of which has two `Person`s, the other of which has one. And so
on. Taxes are always computed per `TaxUnit` and then summed to the household.

### 3.3 Employer and IncomeStream

**Employer:**

| Field         | Type   | Notes  |
|---------------|--------|--------|
| `id`          | ID     |        |
| `householdId` | ID     | Owner. |
| `label`       | string |        |

An `Employer` exists so that an `IncomeStream` and an`Account` can share a reference and so that the
UI can offer a list rather than a text box.

**IncomeStream:**

| Field                        | Type   | Notes                                                                                                                                                                                                                                                                                                                                                                |
|------------------------------|--------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                         | ID     |                                                                                                                                                                                                                                                                                                                                                                      |
| `personId`                   | ID     | Owner: determines whose FICA cap applies.                                                                                                                                                                                                                                                                                                                            |
| `employerId`                 | ID?    | Which `Employer` pays it, matched against `Account.employerId` so the match and §415(c) can see this stream's pay (§3.4). Null where no plan is tied to it.                                                                                                                                                                                                          |
| `label`                      | string |                                                                                                                                                                                                                                                                                                                                                                      |
| `kind`                       | enum   | `w2Wages`, `selfEmployment`, `bonus`, `rsuVesting`, `rentalNet`, `pension`, `other`                                                                                                                                                                                                                                                                                  |
| `grossAnnualAmount`          | Money  | The **full-year** rate. What a partial year actually pays is `resolvedAmount` below, and every §4 sum means that. |
| `realGrowthRate`             | Rate   | **Per stream**, so "my salary grows 1% real, my spouse's is flat" is expressible without one household-wide raise rate.                                                                                                                                                                                                                                              |
| `startYear`                  | int?   | First year the stream is active, and the year `realGrowthRate` compounds from. Null means it is already running, the common case; set it for a job beginning mid-projection or a spouse returning to work.                                                                                                                                                           |
| `endYear`                    | int?   | Last year it is active. **Defaults to the year before the owning Person's `retirementYear`** for the earned kinds (`w2Wages`, `bonus`, `rsuVesting`, `selfEmployment`) and to null, meaning indefinitely, for `rentalNet`, `pension`, and `other`. Set it explicitly for a contract ending, a career change, or a Barista FIRE job that runs past retirement (§9.2). |
| `startMonth`                 | int?   | 1–12, null meaning January. The month the stream begins, which prorates its **first** year only. |
| `endMonth`                   | int?   | 1–12, null meaning December. The month it ends, which prorates its **last** year only. Set both across a job change so the transition year carries the pay actually received rather than two full salaries. |
| `isFicaSubject`              | bool   | Derived from `kind`, overridable.                                                                                                                                                                                                                                                                                                                                    |
| `isQualifiedBusinessIncome`  | bool   | Whether this stream feeds the §199A deduction (§4.3.2). Defaults **true** for `selfEmployment` and `rentalNet`, false otherwise.                                                                                                                                                                                                                                     |
| `isSpecifiedServiceBusiness` | bool   | Whether this is an SSTB (consulting, law, medicine, financial services). Default false. Recorded so the deferred above-threshold limits (§13.2) have somewhere to land, and so `qbiLimitNotModeled` can say *why* it matters.                                                                                                                                        |
| `variability`                | enum   | `guaranteed` \| `variable`. **Display only**, read by no engine calculation. Bonuses and RSUs are flagged as not-guaranteed so a plan resting on them is visibly doing so.                                                                                                                                                                                           |

**A span is prorated in its own first and last year, and only there.** Every entity carrying
`startYear`/`endYear` carries `startMonth`/`endMonth` alongside them, null meaning the whole
year:

```
activeFraction(year) = 1 − (startMonth − 1) / 12   if year = startYear
                         − (12 − endMonth)  / 12   if year = endYear

resolvedAmount(IncomeStream, year) = grossAnnualAmount, grown to that year by
                                       realGrowthRate, × activeFraction(year)
```

`grossAnnualAmount` stays the full-year rate, so growth compounds on the rate and the
proration lands after it. Every §4 sum over `IncomeStream`s means `resolvedAmount`.

The same fraction scales a `PayrollDeduction`'s `annualAmount` (§3.4.5), an `ExpenseItem`'s
inflated amount (§3.7), and a `fixedAmount` `Contribution` (§3.4.1). A `percentOfGross`
`Contribution` takes no scaling of its own, its base already being the streams' resolved
amounts.

This does not contradict §6.4's rule that the pipeline runs on full-year inputs. `frac`
prorates a projection year that is itself partial, and prorating a salary before the
brackets see it would understate the household's effective rate. These months do the
opposite: they produce the income the household genuinely received across the whole year,
which then meets the brackets once. A person leaving one job in July and starting another
in August is carrying one salary, and without them the engine reads two.

**Earned income stops at retirement; unearned income does not.** `endYear` bounds the
span over which `realGrowthRate` compounds, and it stops a salary when its owner
retires. A pension or rental stream keeps its null `endYear` and goes on compounding.

**`grossAnnualAmount` for `selfEmployment` is Schedule C *net profit*.** §4.2's 92.35%
factor and the SEP contribution base are both defined against net earnings, so entering
revenue before business expenses overstates both the SE tax and the deduction it
supports. The field reads the same way `rentalNet` does.

**`kind` drives payroll tax treatment.** `selfEmployment` pays both halves on 92.35% of
net earnings: 12.4% OASDI, sharing the wage-base cap with any W-2 wages the same person
has, plus 2.9% uncapped Medicare, with half the total deductible above the line. §4.2 has
the exact formula, which stops being a flat 15.3% once the wage base binds. `rentalNet`
and `pension` are income-tax-only, with no FICA.

### 3.4 Account

A single entity carrying both the balance (stock) and the contribution rate (flow) for
any savings or investment vehicle.

| Field                       | Type                     | Notes                                                                                                                                                                                                                                                                                                                                                                                                                         |
|-----------------------------|--------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                        | ID                       |                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `personId`                  | ID                       | Owner. Contribution limits are per person. A jointly held cash or brokerage account names either spouse: `limitFamily = none` and the absence of any age gate leave every rule reading this field with the same answer inside one `TaxUnit`. Across two, its interest follows the name.                                                                                                                                       |
| `label`                     | string                   |                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `kind`                      | enum                     | `traditional401k`, `roth401k`, `traditional403b`, `roth403b`, `traditionalTsp`, `rothTsp`, `traditionalIra`, `rothIra`, `hsa`, `sepIra`, `simpleIra`, `529`, `taxableBrokerage`, `cashSavings`, `cashChecking`                                                                                                                                                                                                                |
| `taxTreatment`              | enum                     | `taxDeferred` \| `roth` \| `taxable` \| `hsaTriple` \| `educationTaxFree`: *derived from `kind`*, but stored so custom accounts are expressible.                                                                                                                                                                                                                                                                              |
| `limitFamily`               | enum                     | Which contribution limit governs this account: *derived from `kind`*, stored alongside `taxTreatment` so the two move together (invariant 29). See the table below.                                                                                                                                                                                                                                                           |
| `balance`                   | Money                    | Current value.                                                                                                                                                                                                                                                                                                                                                                                                                |
| `costBasis`                 | Money                    | Required for `taxable`. Entered once, then **maintained by the engine every projected year** (§6.3). Needed to compute capital gains tax on withdrawal or sale.                                                                                                                                                                                                                                                               |
| `rothContributionBasis`     | Money                    | For `roth` accounts: the portion withdrawable before 59½ without tax or penalty. Entered once, then **maintained by the engine** (§6.3). Only an IRA's basis is directly reachable; see §8.4.1's `rothIraBasis` source. Critical to the bridge period (§8.3).                                                                                                                                                                 |
| `rothFirstContributionYear` | int?                     | For `roth` accounts: starts the five-year clock that, together with 59½, qualifies `rothEarnings` withdrawals (§8.4.1). Null means the clock is unknown and unsatisfied, so `rothEarnings` stays unqualified, erring toward the penalty the way §3.1's 59½ rule does.                                                                                                                                                         |
| `contribution`              | Contribution             | The **flow**. See below.                                                                                                                                                                                                                                                                                                                                                                                                      |
| `employerId`                | ID?                      | Which `Employer` sponsors the plan, shared with that person's `IncomeStream`s (§3.3). Null for IRAs and taxable accounts. Resolves `employerComp` below, which bounds both the employer match and §415(c), so someone holding two unrelated employers' 401(k)s gets two ceilings. Also the linkage the deferred Rule of 55 would need (§13.3).                                                                                |
| `allocationMode`            | enum                     | `singleClass` \| `weighted`: user-facing switch between a simple single-`AssetClass` rate and a blended, weighted mix.                                                                                                                                                                                                                                                                                                        |
| `assetAllocationId`         | ID?                      | For `allocationMode = singleClass`: the one `AssetClass` determining growth rate.                                                                                                                                                                                                                                                                                                                                             |
| `allocationWeights`         | {assetClassId, weight}[] | For `allocationMode = weighted`: weights summing to 1.0, blended into a weighted-average real return each year.                                                                                                                                                                                                                                                                                                               |
| `isRestrictedPurpose`       | bool                     | Derived from `taxTreatment = educationTaxFree`, not from `kind`, that being the axis a custom account may set. Keying it on `kind` would let a custom education account count in `liquidNetWorth` with no `WithdrawalSource` able to spend it. Restricted accounts count in `netWorth` but are excluded from `liquidNetWorth` and every retirement measure built on it (§5, §8.2), and are not a `WithdrawalSource` (§8.4.1). |
| `targetBalanceMonths`       | number?                  | Only meaningful for the household's designated cash-buffer account(s), typically `cashSavings`. Expressed as months of `annualExpenses` since expenses change year to year, so the Money target is `targetBalanceMonths × annualExpenses / 12`, recomputed each projected year. Null for every other account. See §4.4.4 step 4 and §4.5.                                                                                     |

**A 529 is net worth.** Spending it on anything else costs income tax plus a 10% penalty on
the earnings, and the household holding one has almost always earmarked it for a specific
child, so a fully funded college account must not push the retirement test (§8.2) over the
line. It is spent by entering the tuition as an `ExpenseItem` under an `education`
category, which §4.4 draws against the balance before anything else pays for it.

**There is no `fsa` account kind.** An FSA is funded and spent inside the same plan year
and anything left over is forfeited, so it has no persistent balance to compound. It is a
`PayrollDeduction` instead (§3.4.5).

### 3.4.1 Contribution (embedded in `Account`)

| Field                         | Type           | Notes                                                                                                                                                                                                                                                                                                                                                 |
|-------------------------------|----------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `mode`                        | enum           | `percentOfGross` \| `fixedAmount`: people set 401(k) as a percent and IRAs as a dollar figure, so both are first-class.                                                                                                                                                                                                                               |
| `value`                       | number         | Percent or Money depending on `mode`.                                                                                                                                                                                                                                                                                                                 |
| `contributionBaseStreamIds`   | ID[]           | Which of the person's `IncomeStream`s the percentage applies to. Required when `mode = percentOfGross`; ignored otherwise.                                                                                                                                                                                                                            |
| `employerMatch`               | EmployerMatch? | The employer's own contribution formula; see the `EmployerMatch` table below.                                                                                                                                                                                                                                                                         |
| `reducesFederalTaxableIncome` | bool           |                                                                                                                                                                                                                                                                                                                                                       |
| `reducesStateTaxableIncome`   | bool           |                                                                                                                                                                                                                                                                                                                                                       |
| `reducesFicaWages`            | bool           |                                                                                                                                                                                                                                                                                                                                                       |
| `startYear`                   | int?           | First year the contribution runs. Null means it is already running, the common case; set it for a job beginning mid-projection or a spouse returning to work.                                                                                                                                                                                         |
| `endYear`                     | int?           | Last year it runs. **Defaults to the year before the owner's `retirementYear`**, matching `IncomeStream.endYear` (§3.3), since a payroll deferral has no pay to come out of once earned income stops and an IRA contribution needs compensation. Set it earlier for Coast FIRE (§9.3), or later for a Barista FIRE job that keeps a plan open (§9.2). |
| `startMonth`                  | int?           | 1–12, null meaning January. Prorates the first year, per §3.3. |
| `endMonth`                    | int?           | 1–12, null meaning December. Prorates the last year, per §3.3. |

**Every formula in §4 that sums `Contribution`s means the resolved dollar amount for the
year.** The raw stored `value` is `resolvedAmount`:

```
base           = Σ resolvedAmount over IncomeStreams in contributionBaseStreamIds  // §3.3
uncapped       = value × activeFraction(year)     if mode = fixedAmount   // §3.3
               = value × base             if mode = percentOfGross

catchUp        = the amount of the TaxYear.contributionLimits[limitFamily].catchUpTiers
                 entry whose age span contains age(year); 0 if none        // §3.12
familyCap      = the limit for this account's limitFamily + catchUp        // table below
capped         = min(uncapped, familyCap)

employerComp   = min(Σ resolvedAmount over this person's IncomeStreams carrying
                       this account's employerId,
                     TaxYear.contributionLimits.compensationLimit401a17)
               = 0  where employerId is null

match          = the EmployerMatch formula below, applied to capped
room415c       = max(0, min(TaxYear.contributionLimits.annualAdditions415c, employerComp)
                        + catchUp − match)
               = ∞  where employerId is null

resolvedAmount = min(capped, room415c)
```

### 3.4.2 Contribution limits

**A plan may not count compensation above `compensationLimit401a17`:** roughly $350,000, for
any purpose, so "50% of the first 6%" on a $500,000 salary is computed on $350,000, a
difference of several thousand dollars a year that the household never receives.

**Catch-up is a set of age tiers.** `catchUpTiers` (§3.12) is an ordered list of
`{fromAge, toAge?, amount}`, because an enlarged catch-up applies from 60 through 63 and then
**reverts** at 64.

**A high earner's catch-up is forced to Roth treatment.** Where the person's prior year
FICA wages from the sponsoring employer exceed
`TaxYear.contributionLimits.rothCatchUpWageThreshold`, the `catchUp` portion of an
`electiveDeferral` contribution is Roth no matter what the account's own `taxTreatment` says:
it reduces no taxable income, and it is credited to that person's designated Roth account in
the same plan, created if absent, since `rothContributionBasis` exists only on a `roth`
account and statute permits the catch-up only where the plan offers one. The prior year's
`ficaWages` comes from the previous `YearResult`, so this needs no new input.

**The cap depends on the account.** Applying the §402(g) elective deferral limit across
the board would let a $23,500 IRA contribution through and cap a taxable brokerage
deposit at a figure that has nothing to do with it:

| `limitFamily`      | Kinds                                                                                     | Cap                                                                                                                                                                                                                                                                                                                                                                                             |
|--------------------|-------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `electiveDeferral` | `traditional401k`, `roth401k`, `traditional403b`, `roth403b`, `traditionalTsp`, `rothTsp` | §402(g) elective deferral + catch-up, **shared per person across every account in the family**; also subject to §415(c) with employer match                                                                                                                                                                                                                                                     |
| `simpleDeferral`   | `simpleIra`                                                                               | The SIMPLE elective limit + its own catch-up, a separate and lower figure than §402(g)                                                                                                                                                                                                                                                                                                          |
| `ira`              | `traditionalIra`, `rothIra`                                                               | One IRA limit + catch-up, **shared across both** per person. `rothIra` is additionally gated by the Roth income limit (§4.4.4 step 5)                                                                                                                                                                                                                                                           |
| `sep`              | `sepIra`                                                                                  | `sepRate / (1 + sepRate)` × (that person's `seNetEarnings − seDeduction`), capped by §415(c). The conversion turns the statutory 25% into the familiar 20% of net earnings; see below                                                                                                                                                                                                           |
| `hsa`              | `hsa`                                                                                     | The self or family limit per the person's active `hsaCoverage` tier (§3.1), **plus their own 55-and-over catch-up**. A `family` tier is one *base* limit shared across the TaxUnit. The catch-up is per person and requires each spouse to hold their own HSA, so it is never shared. `none` permits no HSA contribution, and neither does any year in which the person is 65 or older (below). |
| `education`        | `529`                                                                                     | No federal annual limit (the gift-tax exclusion is not modeled)                                                                                                                                                                                                                                                                                                                                 |
| `none`             | `taxableBrokerage`, `cashSavings`, `cashChecking`                                         | Uncapped                                                                                                                                                                                                                                                                                                                                                                                        |

**The SEP rate is stored as statute writes it and converted in the formula.** Storing the converted
rate in `TaxYear` would put a number in the data that appears in no IRS table, so the next tax-year
update copying 25% from that table would silently break it.

**The elective deferral limit is assessed per person across every account sharing it**: someone who
changed jobs mid-year and holds two `traditional401k`s gets one elective deferral limit between
them,
and someone holding both a `traditionalIra` and a `rothIra` gets one IRA limit between those.

Where the uncapped total across accounts sharing a limit exceeds it, each is reduced pro
rata by its share, matching the rule for splitting a partially funded step of the
**contribution waterfall**, the ordered list of destinations each year's surplus is poured
through (§4.4.4). Later sections call it the waterfall. This is where §12's invariant 20 is
enforced.

**HSA contributions stop at 65**, since Medicare enrollment ends HSA eligibility and the
engine already assumes Medicare at 65 (§8.4.3). `resolvedAmount` is zero for any `hsa`
account in a year where its owner's `age(year) ≥ 65`, the `hsaPayrollToLimit` and
`hsaDirectToLimit` waterfall steps (§4.4.4) skip that person, and
**`hsaContributionsStoppedAtMedicare`** is raised in the first such year.

### 3.4.3 Tax treatment of contributions

**The three `reduces*` flags carry the actual tax treatment of each contribution type.**
401(k), 403(b), and TSP deferrals reduce federal and usually state income tax while
leaving FICA and Medicare wages alone. Only cafeteria-plan items under §125 (HSA via
payroll deduction, FSA, employee-paid insurance premiums) and qualified transportation
benefits under §132(f) reduce FICA wages. The same flags capture state divergence, such as
Pennsylvania taxing 401(k) contributions at the state level.

Defaults by kind:

| Kind                                                                     | Federal                                                       | State                           | FICA                |
|--------------------------------------------------------------------------|---------------------------------------------------------------|---------------------------------|---------------------|
| `traditional401k`, `traditional403b`, `traditionalTsp`, `traditionalIra` | reduces (IRA: subject to the deductibility phase-out, §4.3.1) | reduces (except PA and similar) | **does not reduce** |
| `hsa` via payroll                                                        | reduces                                                       | reduces (except CA, NJ)         | **reduces**         |
| `hsa` direct contribution                                                | reduces                                                       | varies                          | does not reduce     |
| `roth401k`, `roth403b`, `rothTsp`, `rothIra`, `529`                      | no                                                            | no (some states deduct 529)     | no                  |

**A `traditionalIra`'s `reducesFederalTaxableIncome` is not guaranteed.** Whether the deduction is
allowed is a per-year MAGI question decided in §4.3.1, since it depends on income and on
workplace-plan coverage. The flag says the user means to deduct it and the engine decides each year
how much of that is permitted.

### 3.4.4 EmployerMatch (embedded in `Contribution`)

| Field                       | Type                                           | Notes                                                                                                                                                                                                                                                                                                                         |
|-----------------------------|------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `formula`                   | enum                                           | `percentOfContribution` \| `percentOfSalary` \| `tiered`                                                                                                                                                                                                                                                                      |
| `matchRate`                 | Rate                                           | For `percentOfContribution`/`percentOfSalary`. e.g. 0.50 for a 50% match.                                                                                                                                                                                                                                                     |
| `matchLimitPercentOfSalary` | Rate                                           | For `percentOfContribution`/`percentOfSalary`. e.g. 0.06 ("50% of the first 6%").                                                                                                                                                                                                                                             |
| `tiers`                     | {upToPercentOfSalary: Rate, matchRate: Rate}[] | For `formula = tiered` only: ordered tiers, each applying `matchRate` to the slice of contribution between the previous tier's cutoff and this one's `upToPercentOfSalary`. e.g. `[{upToPercentOfSalary: 0.03, matchRate: 1.00}, {upToPercentOfSalary: 0.05, matchRate: 0.50}]` = "100% of the first 3%, 50% of the next 2%." |
| `vestingSchedule`           | VestingSchedule?                               | `immediate` \| `cliff(years)` \| `graded(schedule)`. **Warning only**; see below.                                                                                                                                                                                                                                             |

```
employeePct = capped / employerComp                     // 0 where employerComp is 0

match = matchRate × min(capped, matchLimitPercentOfSalary × employerComp)
                                     if formula = percentOfContribution
      = matchRate × employerComp     if formula = percentOfSalary
                                     and employeePct ≥ matchLimitPercentOfSalary,
                                     else 0
      = Σ over tiers, in order:      if formula = tiered
          tier.matchRate × employerComp
            × max(0, min(employeePct, tier.upToPercentOfSalary)
                     − previous tier's upToPercentOfSalary)
```

A match needs an `employerId` with pay behind it: `employerComp` of zero yields no match,
which is the right answer for an account no employer sponsors. `percentOfContribution`
applies its rate to the employee's own dollars, `percentOfSalary` to pay once the employee
clears a participation threshold, and a `matchLimitPercentOfSalary` of 0 there makes it a
non-elective contribution owed regardless. The resulting employer dollars are bounded by
`room415c`.

**`vestingSchedule` does not reduce any balance.** It is recorded, and the projection
raises `unvestedMatchAtRisk` when a `cliff` or `graded` schedule exists and the projected
retirement year falls inside it, because walking away at three years against a five-year
cliff forfeits real money.

### 3.4.5 PayrollDeduction

Pre-tax money that is spent. Structurally the sibling of `Contribution`: same three tax flags, same
place in §4.1 and §4.3, with no balance and no growth.

| Field                         | Type   | Notes                                                                                                                                                                                                                                                                                                                                                                                             |
|-------------------------------|--------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                          | ID     |                                                                                                                                                                                                                                                                                                                                                                                                   |
| `personId`                    | ID     | Owner. Payroll deductions are per employee, and FICA is assessed per person.                                                                                                                                                                                                                                                                                                                      |
| `label`                       | string |                                                                                                                                                                                                                                                                                                                                                                                                   |
| `kind`                        | enum   | `healthPremium`, `dentalVisionPremium`, `healthFsa`, `dependentCareFsa`, `commuterBenefit`, `other`                                                                                                                                                                                                                                                                                               |
| `annualAmount`                | Money  | Normalized to annual, like `ExpenseItem.frequency`, and scaled by `activeFraction(year)` in the deduction's first and last year (§3.3), so an FSA election on a job that ends in July deducts seven months.                                                                                                                                                                                                                                                                                                                                               |
| `reducesFederalTaxableIncome` | bool   | Derived from `kind`, overridable: true for the pre-tax kinds. A premium can be post-tax, domestic-partner coverage being the common case.                                                                                                                                                                                                                                                         |
| `reducesStateTaxableIncome`   | bool   | Derived from `kind`, overridable, with the same state divergence as `Contribution` (§3.4.3). All three override independently, a premium being pre-tax federally and post-tax in some states.                                                                                                                                                                                                     |
| `reducesFicaWages`            | bool   | Derived from `kind`, overridable, over the same pre-tax set. **This is the only way to express it**, since an `ExpenseItem` cannot reduce FICA wages.                                                                                                                                                                                                                                             |
| `expenseCategoryId`           | ID?    | Which `ExpenseCategory` this spending would otherwise have appeared under, for reporting only.                                                                                                                                                                                                                                                                                                    |
| `startYear`                   | int?   | First year the deduction runs. Null means it is already running.                                                                                                                                                                                                                                                                                                                                  |
| `endYear`                     | int?   | Last year it runs. Defaults to that person's `employerHealthCoverageEndYear` (§3.1) for the coverage-related kinds, so a premium and the coverage it buys end together, and to the year before their `retirementYear` for the rest, a deduction needing a paycheck to come out of. An employer retiree premium runs past retirement and simply reduces no wages, there being none left to reduce. |
| `startMonth`                  | int?   | 1–12, null meaning January. Prorates the first year, per §3.3. |
| `endMonth`                    | int?   | 1–12, null meaning December. Prorates the last year, per §3.3. |

**This is where pre-tax payroll money lives.**

The money never reaches the paycheck, so §4.4 subtracts `payrollDeductions` from
`grossIncome` directly and the corresponding spending must not also appear as an
`ExpenseItem` (invariant 16).

### 3.5 Asset

Holdings that are not accounts. `Account` covers savings and investment vehicles; `Asset`
covers everything else the household owns.

| Field                      | Type   | Notes                                                                                                                                                                                                                                                                                |
|----------------------------|--------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                       | ID     |                                                                                                                                                                                                                                                                                      |
| `householdId`              | ID     | Owner.                                                                                                                                                                                                                                                                               |
| `personId`                 | ID?    | Which person owns this, and so whose `TaxUnit` its sale gain is taxed on (§4.3.1). Null means jointly held, which resolves to the household's only `TaxUnit` and must therefore be set once there are two (invariant 25).                                                            |
| `label`                    | string |                                                                                                                                                                                                                                                                                      |
| `category`                 | enum   | `primaryResidence`, `investmentProperty`, `vehicle`, `collectible`, `businessEquity`, `other`                                                                                                                                                                                        |
| `currentValue`             | Money  | Today's estimate, and an ordinary input. Re-enter it after an appraisal: every run projects forward from `asOfDate`, so a revised figure takes effect at once and `costBasis` is unaffected.                                                                                         |
| `costBasis`                | Money  | Basis for gain on sale, entered as purchase price plus improvements to date. Static across the projection, unlike `Account.costBasis` (§6.3): later improvements are not modeled (§13.1).                                                                                            |
| `realAppreciationRate`     | Rate   | Per asset, defaulted from category, user-overridable. Vehicles default negative. One rate across all three bands, since a home is not where the plan's risk sits.                                                                                                                    |
| `accumulatedDepreciation`  | Money  | `investmentProperty` only. Straight-line depreciation claimed to date; entered as an opening figure and **accrued by the engine each year the property is held** (below). Reduces basis, so it raises the gain on sale, and is taxed at its own rate. Zero for every other category. |
| `landFraction`             | Rate   | `investmentProperty` only. Portion of `costBasis` attributable to land, which is not depreciable. Default 0.20.                                                                                                                                                                      |
| `securedByLiabilityId`     | ID?    | Links a house to its mortgage.                                                                                                                                                                                                                                                       |
| `acquisitionYear`          | int?   | Year the household takes ownership. Null means already held, the common case. Before it the `Asset` is absent from every net-worth measure: see the purchase rules below.                                                                                                            |
| `purchaseFundingAccountId` | ID?    | Where the down payment is drawn from. Null for an `Asset` acquired without paying for it.                                                                                                                                                                                            |
| `plannedSaleYear`          | int?   | Year the household sells it. The only way an `Asset`'s value becomes spendable: see the sale rules below.                                                                                                                                                                            |
| `saleProceedsAccountId`    | ID?    | Where net proceeds land. **Required when `plannedSaleYear` is set** (invariant 18), since proceeds that go nowhere silently vanish from the projection.                                                                                                                              |

**No `Asset` is ever liquid.**

An `Asset` becomes spendable by being sold. `plannedSaleYear` runs the sale rules below,
the proceeds land in `saleProceedsAccountId`, and from that year they are reachable
through the ordinary withdrawal sources (§8.4.1).

**Purchase rules.** When §6 reaches `acquisitionYear` for an `Asset`:

```
mortgage    = the securing Liability's currentBalance, or 0 where none
downPayment = max(0, costBasis − mortgage)

draw downPayment from purchaseFundingAccountId; a shortfall is sourced per §4.4
the Asset enters every net-worth measure at costBasis and appreciates from this year
the securing Liability begins amortizing at its originationDate (§3.6)
```

`currentValue` applies only to an `Asset` already held; one acquired later enters at what
it cost. A null `purchaseFundingAccountId` means no money changed hands, which is how an
inheritance is expressed: `costBasis` is that year's fair market value, the stepped-up basis
statute gives it, and no draw occurs.

**Sale rules.** When §6 reaches `plannedSaleYear` for an `Asset`:

```
grossProceeds = currentValue projected to that year
sellingCosts  = Assumptions.assetSaleCostRate × grossProceeds
                  if category in (primaryResidence, investmentProperty), else 0
netProceeds   = grossProceeds − sellingCosts
adjustedBasis = costBasis − accumulatedDepreciation
gain          = max(0, netProceeds − adjustedBasis)
exclusion     = TaxYear.section121Exclusion[filingStatus]  if category = primaryResidence
              = 0                                           otherwise

recapture     = min(accumulatedDepreciation, gain)   → taxed at
                TaxYear.unrecapturedSection1250Rate, NOT the LTCG schedule, and NOT
                shelterable by the §121 exclusion
taxableGain   = max(0, gain − recapture − exclusion) → realizedLongTermGains (§4.3.1)

if securedByLiabilityId is set:
    that Liability is retired in full; netProceeds −= its currentBalance
    its debtService stops from this year forward, and its escrow resolves per §3.6
    a negative result is an underwater sale: it enters that year's netSurplus as a
    cost and is sourced per §4.4, flagging shortfall

deposit netProceeds into saleProceedsAccountId, increasing that account's costBasis
  by the same amount
remove the Asset from every net-worth measure from this year forward
```

**Depreciation is claimed every year and paid for once.** While an `investmentProperty`
is held, the engine accrues

```
annualDepreciation = costBasis × (1 − landFraction)
                       / TaxYear.residentialDepreciationYears     // 27.5
```

capped so `accumulatedDepreciation` never exceeds the depreciable basis, and deducts it
from that property's **taxable** rental income in §4.3. A deduction moves no cash, so it
never touches `grossIncome` in §4.4, and `IncomeStream.grossAnnualAmount` for a `rentalNet`
stream is net cash flow **before** depreciation.

On sale it comes back. Depreciation lowers basis, so the gain is larger by the full
amount claimed, and the portion attributable to it is unrecaptured §1250 gain taxed at a
flat 25%. The §121 exclusion cannot shelter it even where the property was later a
primary residence, which is why `recapture` is subtracted before `exclusion` applies.
Modeling the deduction alone would make a rental look like a permanent tax shelter, and
modeling the recapture alone would be a penalty with no benefit attached.

Selling costs are large: commission, transfer taxes, and closing costs run to roughly 6%
on residential property, tens of thousands of dollars on the exact transaction a
downsizing plan turns on. `assetSaleCostRate` defaults accordingly. It is one rate, scoped by
`category`, so a vehicle or a collectible sells at no modeled cost.

The §121 exclusion assumes the two-of-five-years ownership-and-use test is met, which is
true for a primary residence the household lives in. An investment property gets no
exclusion, which is why `category` gates it.

### 3.6 Liability

Debts, tracked as first-class entities rather than folded into net worth or expenses.

| Field                            | Type       | Notes                                                                                                                                                                                                                                                                                         |
|----------------------------------|------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                             | ID         |                                                                                                                                                                                                                                                                                               |
| `householdId`                    | ID         | Owner.                                                                                                                                                                                                                                                                                        |
| `personId`                       | ID?        | Who owes it, and so whose `TaxUnit` deducts its interest (§4.3.1). Null as in §3.5.                                                                                                                                                                                                           |
| `label`                          | string     |                                                                                                                                                                                                                                                                                               |
| `kind`                           | enum       | `mortgage`, `autoLoan`, `studentLoan`, `creditCard`, `personalLoan`, `heloc`, `other`                                                                                                                                                                                                         |
| `currentBalance`                 | Money      |                                                                                                                                                                                                                                                                                               |
| `interestRate`                   | Rate       | **Nominal, and used nominally**: the amortization schedule runs on the contract's own terms. Converted to real only for comparison (§4.4's `highInterestDebt` step) and when the resulting payment enters the real-dollar pipeline. See below.                                                |
| `monthlyPayment`                 | Money      | **Authoritative for cash flow**: what actually leaves the account each month, and what §4.4's `debtService` term sums.                                                                                                                                                                        |
| `monthlyEscrowAmount`            | Money?     | The non-amortizing portion of `monthlyPayment` collected by the servicer. **Optional, inferred when null** (see below).                                                                                  |
| `monthlyPmiAmount`               | Money?     | PMI, if the payment includes it. **A component of the escrow total**, broken out separately because it ends on its own schedule, usually years before payoff. Dropping it reduces both `monthlyPayment` and the escrow inside it.                                                             |
| `principalAndInterest`           | Money      | **Derived**: `monthlyPayment − monthlyEscrow` (below). What actually amortizes the loan, and what the payoff derivation runs on. |
| `escrowContinuesAfterPayoff`     | Rate       | What fraction of the escrow the household keeps paying once the loan is gone. **Default 1.0.**                                                                                                                                                                                                |
| `extraPrincipalPayment`          | Money      | Additional monthly principal the household pays voluntarily. Default 0. Amortizes the loan faster and reaches cash flow through §4.4's `debtService` term. This is a standing choice the user has already made, distinct from the engine-directed `highInterestDebt` waterfall step (§4.4.4). |
| `originationDate`                | date       | First payment date. A future one is the financing half of an `Asset` acquisition (§3.5), where the purchase rule nets the borrowed principal against the price; borrowing that funds no acquisition is deferred (§13.1). |
| `termMonths`                     | int        | Length of the loan. With `originationDate` it yields a contractual payoff year, which the derived one below may disagree with. |
| `securedAssetId`                 | ID?        | The `Asset` this debt is secured by, and the mirror of `Asset.securedByLiabilityId` (invariant 5). Null for unsecured debt.                                                                                                                                                                   |
| `isTaxDeductibleInterest`        | bool       | Mortgage interest and student loan interest, subject to limits. Student loan interest feeds `deductibleStudentLoanInterest` (§4.3.1); mortgage interest feeds itemized deductions, whose derivation is deferred (§13.2).                                                                      |

**Debt service reaches cash flow through `debtService` (never through an `ExpenseItem`).**
§4.4 sums `12 × (monthlyPayment + extraPrincipalPayment)` across active liabilities
directly. Invariant 15 is relevant here.

**Payoff changes the FIRE number.** A mortgage retiring in 2041 removes a large recurring
expense at a known date, which lowers required retirement spending and therefore the FIRE
number. The FIRE number prices the whole retirement spending stream, so the years after
payoff pull the required portfolio down by the discounted value of the payments avoided.

**Escrow is inferred when it is not entered.** A household knows its total payment and often
nothing else, so requiring a breakdown into property tax, insurance, PMI, and HOA would
gate one of the first entities anyone enters on an annual escrow analysis they would have
to go find. The engine derives it:

```
remainingMonths = termMonths − max(0, monthsElapsed(originationDate, asOfDate))
                  // 0 before origination, so a future loan keeps its full term
scheduledPandI  = amortizationPayment(currentBalance, interestRate / 12, remainingMonths)
inferredEscrow  = max(0, monthlyPayment − scheduledPandI)

monthlyEscrow   = monthlyEscrowAmount ?? inferredEscrow
```

An entered `monthlyEscrowAmount` wins, and a material disagreement with `inferredEscrow`
raises **`escrowDiffersFromInferred`**, the same warn-don't-block posture the payment fields
get below.

**The escrow *account* ends at payoff; the obligations inside it do not.** The servicer
stops collecting and the homeowner pays the county and the insurer directly, so several
thousand dollars a year of permanent cost survives the payoff. Dropping the whole payment
would take that straight off the FIRE number.

At the derived payoff year the engine drops P&I, carries `monthlyEscrow ×
escrowContinuesAfterPayoff` inside §4.4's `debtService` for as long as the securing `Asset`
is held, and raises **`payoffLeavesResidualEscrow`** naming the continuing figure. The 1.0
default suits the ordinary case, tax and insurance being the bulk of escrow, and errs toward
overstating retirement expenses. Lower it where some of the escrow is already an
`ExpenseItem`, such as a directly billed HOA.

**PMI ends on its own schedule, usually long before the mortgage.** The engine drops
`monthlyPmiAmount` in the first projected year where `currentBalance ≤ pmiTerminationLtv ×
securedAsset.costBasis`.

**Amortize nominally, then deflate.** A lender fixes the schedule in nominal terms, and
inflation changes neither the payment nor the 360 months. Where a real rate is needed for comparison
it is the exact Fisher conversion `(1 + interestRate) / (1 +generalInflationRate) − 1`, since the
gap against simple subtraction compounds over 30 years.

**The payment fields are over-determined, and `monthlyPayment` wins.** `currentBalance`,
`interestRate`, `monthlyPayment`, and `originationDate`/`termMonths` are entered
independently and routinely disagree, because real statement payments bundle escrow and
users round. The payoff date is therefore **derived** from `currentBalance`,
`interestRate`, and `principalAndInterest`; where the derived payoff and `termMonths`
disagree materially, raise `derivedPayoffDiffersFromTerm` and keep the derived figure,
matching the warn-don't-block posture of §12.

### 3.7 ExpenseCategory and ExpenseItem

A two-level structure: a meta-category groups related sub-category items.

**ExpenseCategory:**

| Field                      | Type   | Notes                                                                                                         |
|----------------------------|--------|---------------------------------------------------------------------------------------------------------------|
| `id`                       | ID     |                                                                                                               |
| `householdId`              | ID     | Owner.                                                                                                        |
| `label`                    | string |                                                                                                               |
| `metaCategory`             | enum   | `housing`, `transportation`, `food`, `health`, `childcare`, `discretionary`, `insurance`, `education`, `misc` |
| `defaultRelativeInflation` | Rate   | **Non-null**, defaulting to 0, which terminates the fallback below.                                           |

Two `metaCategory` values are load-bearing beyond reporting. §8.4.1's `hsaQualifiedMedical`
withdrawal source is capped at that year's spending in `health`, into which the engine also
books its own health insurance cost (§4.4), being the ACA premium net of the credit before
65 and Medicare plus IRMAA after. That is why no `ExpenseItem` may restate a health
premium: it would be counted twice and would inflate the HSA withdrawal cap with it.
Spending in `education` draws a `529` balance down (§4.4), so a tuition line filed
anywhere else leaves the college account untouched.

**ExpenseItem:**

| Field                   | Type   | Notes                                                                                                                                                                                                                                                               |
|-------------------------|--------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                    | ID     |                                                                                                                                                                                                                                                                     |
| `categoryId`            | ID     | Owner, and exactly one. The `Household` is that category's.                                                                                                                                                                                                         |
| `label`                 | string |                                                                                                                                                                                                                                                                     |
| `amount`                | Money  |                                                                                                                                                                                                                                                                     |
| `frequency`             | enum   | `monthly`, `quarterly`, `annual`: normalized to annual on save. A one-off amount is a `OneTimeEvent` (§3.8), so there is no `oneTime` frequency here.                                                                                                               |
| `startYear`             | int?   | First year the item is spent. Null means it is already running.                                                                                                                                                                                                     |
| `endYear`               | int?   | Last year it is spent. Daycare for six years, college for four.                                                                                                                                                                                                     |
| `startMonth`            | int?   | 1–12, null meaning January. Prorates the first year, per §3.3. |
| `endMonth`              | int?   | 1–12, null meaning December. Prorates the last year, per §3.3. |
| `relativeInflationRate` | Rate?  | **Real, relative to general inflation.** Healthcare ≈ +2.5%; groceries ≈ 0%; consumer electronics negative. Null inherits the category's `defaultRelativeInflation`, which is the whole point of that field; a stored 0 is a deliberate flat rate and overrides it. |
| `phase`                 | enum   | `preRetirementOnly` \| `postRetirementOnly` \| `both`. The boundary is the household's `retirementYear`, its first retired year (§3.1), so a `preRetirementOnly` item runs through the year before it and a `postRetirementOnly` item from it.                      |
| `postRetirementAmount`  | Money? | For `both` items whose amount changes at retirement.                                                                                                                                                                                                                |

**Relative inflation compounds; nothing else about an expense does.** An `ExpenseItem`'s
amount for a projected year is

```
rate           = relativeInflationRate ?? its category's defaultRelativeInflation
amount(year)   = amount × (1 + rate)^(year − currentYear) × activeFraction(year)   // §3.3
```

and `postRetirementAmount` inflates from the same base year on the same rate. A zero rate,
the default for most categories, leaves the amount flat in real terms, §1.1's
meaning of holding today's dollars. Healthcare at +2.5% real doubles over 28 years, and
since it is the dominant expense of an early retirement, leaving it flat understates
`retirementAnnualExpenses` and the FIRE number built on it (§8.1) by a wide margin.

`defaultRelativeInflation` sets the rate once for every line
beneath it, and an item's own `relativeInflationRate` overrides it where set.

**`phase` flips once, at the household's retirement year.**

Per-person retirement is preserved wherever it changes a tax answer: each person's
earned `IncomeStream`s and committed contributions end at their own retirement year (§3.3,
§3.4.1), their employer health coverage ends with it (§3.1), and their account access,
catch-up eligibility, and claiming age turn on their own `birthDate`.

**No `ExpenseItem` may restate a loan payment, its escrow, a `PayrollDeduction`, a health
insurance premium, or an `OneTimeEvent` outflow** (invariant 16).

### 3.8 OneTimeEvent

A purchase is an `OneTimeEvent` instead of an `Asset` when the household stops tracking the thing
bought.

| Field          | Type   | Notes                                                                                                                                                                                                                                                                                                                                                                                                        |
|----------------|--------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`           | ID     |                                                                                                                                                                                                                                                                                                                                                                                                              |
| `householdId`  | ID     | Owner.                                                                                                                                                                                                                                                                                                                                                                                                       |
| `personId`     | ID?    | Who receives or pays it, and so whose `TaxUnit` its `taxTreatment` reaches. Null as in §3.5.                                                                                                                                                                                                                                                                                                                 |
| `label`        | string |                                                                                                                                                                                                                                                                                                                                                                                                              |
| `year`         | int    |                                                                                                                                                                                                                                                                                                                                                                                                              |
| `amount`       | Money  | Signed: positive inflow, negative outflow.                                                                                                                                                                                                                                                                                                                                                                   |
| `kind`         | enum   | `inheritance`, `tuition`, `majorRepair`, `vehiclePurchase`, `windfall`, `other`. A label; no engine rule branches on it.                                                                                                                                                                                                                                                                                     |
| `accountId`    | ID?    | Destination for an inflow; **source for an outflow**. Required for outflows (invariant 17): where the $40,000 for a truck comes from changes the projection materially, and only the user knows. An inflow with no account named lands in that year's `netSurplus`. If the named account cannot cover an outflow, the remainder falls through to `netSurplus` and is sourced per §4.4, flagging `shortfall`. |
| `taxTreatment` | enum   | `nonTaxable`, `ordinaryIncome`, `capitalGainShortTerm`, `capitalGainLongTerm`: the two capital-gain kinds feed `realizedShortTermGains`/`realizedLongTermGains` in §4.3.1 respectively.                                                                                                                                                                                                                      |

### 3.9 AssetClass and Assumptions

**AssetClass:**

| Field                     | Type | Notes                                                                 |
|---------------------------|------|-----------------------------------------------------------------------|
| `id`                      | ID   |                                                                       |
| `label`                   | enum | `usStocks`, `intlStocks`, `bonds`, `reit`, `cash`, `crypto`           |
| `expectedRealReturn`      | Rate | The middle band.                                                      |
| `pessimisticRealReturn`   | Rate | The low band.                                                         |
| `optimisticRealReturn`    | Rate | The high band.                                                        |
| `incomeYield`             | Rate | Dividends and interest paid out, as a fraction of balance. See below. |
| `qualifiedIncomeFraction` | Rate | The portion of `incomeYield` taxed at preferential rates (§4.3.3).    |

**`incomeYield` is the cash the holding pays out, dividends and interest, as a fraction of
balance, and it decomposes the return without adding to it.** Total return arrives in
two forms with different tax treatment: distributions taxed in the year received even when
reinvested, and appreciation taxed only when realized. For each band:

```
incomeReturn       = incomeYield                     // identical across all three bands
appreciationReturn = <band>RealReturn − incomeYield   // pessimisticRealReturn,
                                                     // expectedRealReturn, or
                                                     // optimisticRealReturn
```

Adding this field must not move any projected balance: a 5% `expectedRealReturn` with a
1.3% `incomeYield` is 3.7% appreciation, **not** 6.3% of total return. `incomeYield` is a
ratio of income to balance rather than a growth rate, so it needs no real/nominal
conversion, and applied to a real balance it produces real income.

One yield serves all three bands because distribution yields are far more stable than
total returns, so the band spread lives almost entirely in appreciation. Where
`pessimisticRealReturn < incomeYield`, appreciation goes negative, which is permitted and
realistic: a bad year still pays its dividend while the principal falls.

`qualifiedIncomeFraction` is the portion of the yield taxed at preferential rates (§4.3.3's
`qualifiedDividends`), the remainder being ordinary income. It sits near 1.0 for broad
stock funds and at 0 for `bonds` and `cash`. `reit` is why the field has to exist: REIT
distributions are largely ordinary income, so a REIT-heavy taxable account carries a
materially higher tax drag than its headline yield suggests.

**Assumptions** (per `Scenario`):

| Field                           | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
|---------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `generalInflationRate`          | Display and input conversion only (§1.1), and the rate §7.4 deflates non-indexed thresholds by, which makes it load-bearing.                       Default 0.025.                                                                                                                                                                                                                                                                                                                                                      |
| `safeWithdrawalRate`            | Real. Default 0.04.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `contributionWaterfall`         | `WaterfallStep[]` (§4.4.4): an ordered subset of the fixed step-kind vocabulary, since a scenario may omit steps as Coast FIRE does (§9.3). **Not account IDs**: each step sweeps every eligible account of that kind across the household.                                                                                                                                                                                                                                                                                                                                  |
| `withdrawalOrder`               | `WithdrawalSource[]` (§8.4.1): an ordered list of tax-character source kinds. **Not account IDs**, for the same reason as `contributionWaterfall`.                                                                                                                                                                                                                                                                                                                                                                     |
| `highInterestDebtThresholdRate` | **Real** rate, default 0.06. A `Liability` whose real rate (§3.6) exceeds this is paid down by the `highInterestDebt` waterfall step (§4.4.4) ahead of Roth/401(k)/brokerage funding. Real so it compares like-for-like against `AssetClass` real returns, since paying down debt is an investment decision and both sides need the same units (§1.1). Fixed rather than derived from the active band's return, so a plan's debt strategy does not silently differ between its pessimistic and optimistic projections. |
| `includeSocialSecurity`         | bool, default true. Scenario-level master switch: when false, no person's benefit is counted anywhere (§4.3.1, §8.4) regardless of their own `includeInProjection` (§3.11). Both must be true for a benefit to appear, so the scenario flag answers "what if Social Security isn't there at all" and the per-person flag answers "I count on mine but not my spouse's."                                                                                                                                                |
| `capitalGainsRealizationRate`   | Fraction of taxable-account unrealized gains realized annually in years the household is not drawing down (§6). Default 0.05, standing for periodic rebalancing; fund distributions are already carried by `incomeYield` (§3.9) and must not be counted here again.                                                                                                                                                                                                                                                    |
| `projectionHorizonAge`          | Default 95: the age the portfolio must survive to, evaluated against the **youngest** person in the household (§8.2).                                                                                                                                                                                                                                                                                                                                                                                                  |
| `acaMagiCeilingPercentOfFpl`    | Default 200%. Pre-65 MAGI ceiling for subsidy-aware withdrawal ordering (§8.4.4). From 63 onward the engine takes the lower of this and the next IRMAA threshold, because of IRMAA's two-year lookback.                                                                                                                                                                                                                                                                                                                |
| `pmiTerminationLtv`             | Default 0.78. The loan-to-value at which PMI drops off a mortgage, measured against the securing `Asset`'s `costBasis` (§3.6).                                                                                                                                                                                                                                                                                                                                                                                         |
| `assetSaleCostRate`             | Default 0.06: agent commission, transfer taxes, and closing costs on an `Asset` sale, charged on real-property categories only (§3.5).                                                                                                                                                                                                                                                                                                                                                                                 |
| `taxYearId`                     | Which bundled ruleset to project under.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |

### 3.10 Scenario

A **named, saved set of `Assumptions`** applied to a household, comparable side by side
against other scenarios.

| Field         | Type        | Notes                                                                                                    |
|---------------|-------------|------------------------------------------------------------------------------------------------------------|
| `id`          | ID          |                                                                                                          |
| `householdId` | ID          | Owner.                                                                                                   |
| `label`       | string      | "Retire in Colorado at 55", "coast from 45", "one income for three years".                               |
| `assumptions` | Assumptions | The whole set (§3.9), carried rather than referenced, so a scenario keeps the numbers it was saved with. |

**A `Scenario` varies `Assumptions` only; differing household *data* means a cloned
`Household`.** So "what if markets return 4%" is a scenario, and "what if I take the other job" is a clone: change that household's `IncomeStream`s and compare the two side by side
through §10.2, which compares any two snapshots and names what differs. Band return rates
are a third case neither route
reaches: they sit on `AssetClass` (§3.9), which no `Household` owns, so "the same plan at 4%
instead of 5%" cannot be saved and compared. Per-scenario rates are deferred (§13.1). The
alternative,
one household backed by a sparse per-entity override
layer, puts a merge step between every entity and every reader of it and brings precedence
rules, override lifecycle, and comparison semantics with it. Cloning trades a little
duplication for an engine that takes exactly one household and one `Assumptions` with
nothing in between, and under local-only storage (§1.4) a household is small enough that
the duplication costs nothing measurable.

The cost is real: changing a shared fact such as a salary or a new child means changing it
in every scenario that should reflect it, and the app should make that visible. Sharing one
household across scenarios is deferred (§13.1).

### 3.11 SocialSecurityBenefit

| Field                          | Notes                                                                                                                                                                                                    |
|--------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `personId`                     |                                                                                                                                                                                                          |
| `estimatedMonthlyBenefitAtFra` | From the user's SSA statement.                                                                                                                                                                           |
| `claimingAge`                  | 62–70, whole years (consistent with the engine's annual granularity, §1.2), and enforced by invariant 27, since                                   §3.11's delayed-retirement term has no cap of its own. |
| `includeInProjection`          | bool: users vary in whether they want to count on it.                                                                                                                                                    |

**Claiming-age adjustment.** `estimatedMonthlyBenefitAtFra` is the benefit at full
retirement age; claiming away from FRA changes the monthly amount, and FRA itself depends
on birth year (66 for anyone born 1943–1954, rising in two-month steps to 67 for anyone
born 1960 or later):

```
fraMonths      = TaxYear.socialSecurityFraByBirthYear[birthDate.year]  // months, e.g. 794 = 66y 2mo
claimingMonths = claimingAge × 12

monthsEarly    = max(0, fraMonths − claimingMonths)
monthsLate     = max(0, claimingMonths − fraMonths)

c              = TaxYear.claimingAdjustment              // §3.12
adjustmentFactor = 1 − min(monthsEarly, c.earlyFirstMonths) × c.earlyRate
                     − max(0, monthsEarly − c.earlyFirstMonths) × c.earlyRateBeyond
                     + monthsLate × c.delayedRate

adjustedMonthlyBenefit = estimatedMonthlyBenefitAtFra × adjustmentFactor
```

The result is a real monthly figure that stays **flat** for the rest of the projection,
since real dollars throughout (§1.1) already assume COLA tracks inflation. This
computation runs once, at `claimingAge`; §4.3.1 and §8.4 consume `adjustedMonthlyBenefit`
and never `estimatedMonthlyBenefitAtFra` directly. Assumes birth year 1943 or later, since
the phased-in pre-1943 delayed-credit rates are out of scope.

**Three real effects the engine does not model**, all of which the UI must disclose where
the benefit is shown:

- **Early retirement lowers the statement figure itself.** Stopping work decades before
  FRA reduces `estimatedMonthlyBenefitAtFra` relative to the SSA statement's projection,
  which assumes continued earnings. This is separate from the claiming-age adjustment and
  is not corrected for.
- **Spousal benefits** (§13.3). The UI instructs a low- or no-earning spouse to enter the
  **greater** of their own SSA estimate and half of their spouse's FRA figure.
- **The retirement earnings test** (§13.3). Claiming before FRA while still working
  withholds part of the benefit, which is exactly the Barista FIRE shape (§9.2). The engine pays the
  benefit in full and raises **`earningsTestNotModeled`** in any year a person claims before
  their FRA with earned income, the withholding being unmodelled but its condition exactly
  detectable.

### 3.12 TaxYear (reference data)

Versioned, bundled, immutable. **Every statutory rate and threshold lives here**, so a new
tax year is a data change rather than a code change. That covers the ones statute has never
restated, such as the 50% and 85% Social Security inclusion factors and the 20% §199A rate:
`(fixed)` marks a figure that does not index, and it stays data all the same. The exceptions
are 59½ and 65, written into the rules directly because the model is shaped around them. An
age that has moved, such as the RMD age, is data like the rest.

**Every threshold carries an `indexed` flag.** Real-dollar projection (§1.1) holds indexed
figures constant and must *deflate* the ones statute never adjusts (§7.4). Which is which
is a property of the datum, so it is recorded on the datum: a prose list of exceptions goes
stale the moment a threshold's treatment changes in statute, and goes stale silently.
Marked `indexed: false` below with **(fixed)**, attached to the threshold it governs. Rates
carry no flag, deflating one being meaningless: 3.8% is 3.8% in any year.

**A table keyed by age or size continues past its last row.** `federalPovertyLevel` carries
the per-additional-person increment its guidelines publish, the denominator of every ACA
subsidy; `rmdDivisorTable` and `rmdAgeByBirthYear` saturate at their final rows, as the
Uniform Lifetime Table's own "120 and older" entry does. `socialSecurityFraByBirthYear` states
a floor instead (§3.11). Composed of:

*Income tax*

- `federalBrackets[filingStatus]`: ordinary income
- `federalLtcgBrackets[filingStatus]`: 0% / 15% / 20% preferential rates
- `standardDeduction[filingStatus]`
- `additionalStandardDeductionAge65`: applied **per qualifying person** in the TaxUnit
  (§4.3.2)
- `qbiDeductionRate` (0.20) **(fixed)** and `qbiThreshold[filingStatus]`, above which the §199A wage
  and SSTB limits begin.
  Recorded so the engine can raise `qbiLimitNotModeled`, since those limits are deferred
  (§13.2)
- `studentLoanInterestCap` **(fixed)** and `studentLoanInterestPhaseOut[filingStatus]`
  (indexed): the deduction ceiling, and the `{lower, upper}` MAGI range over which it
  phases out. The two are treated differently, which is why they cannot share one flag
  (§4.3, §7.4)

*Payroll tax*

- `socialSecurityWageBase`, `oasdiRate` (0.062), `medicareRate` (0.0145)
- `seNetEarningsFactor` (0.9235). The self-employment OASDI and Medicare rates are
  **derived** as twice the employee rates, so the two cannot drift
  apart (§4.2)
- `additionalMedicareRate` (0.009) and `additionalMedicareThreshold[filingStatus]` **(fixed)**:
  **(fixed)**
- `niitThreshold[filingStatus]` **(fixed)**, `niitRate` (0.038), the net investment income
  tax (NIIT), a surtax on investment income above the threshold:

*Social Security*

- `socialSecurityTaxabilityThresholds[filingStatus]`: the `{lower, upper}`
  provisional-income thresholds from §4.3.1 ($25,000/$34,000 single, $32,000/$44,000 joint
  as of this writing; $0/$0 for `marriedFilingSeparately`). **(fixed)**, never adjusted
  since enactment (§7.4).
- `socialSecurityTaxableFractions` **(fixed)**: the `{half, cap}` §86 inclusion fractions,
  0.5 and 0.85, the share of benefits taxable in each band (§4.3.1)
- `socialSecurityFraByBirthYear`: full retirement age in months, keyed on
  `birthDate.year` (§3.11)
- `claimingAdjustment` **(fixed)**: `{earlyFirstMonths: 36, earlyRate: 5/9 %/mo,
  earlyRateBeyond: 5/12 %/mo, delayedRate: 2/3 %/mo}`, the reduction for claiming before
  full retirement age and the credit for claiming after (§3.11)

*Contributions and accounts*

- `contributionLimits`, keyed by `limitFamily` (§3.4.2). `electiveDeferral`, `simpleDeferral`
  and `ira` carry one amount, `hsa` carries a self and a family amount, `sep` carries the
  statutory rate, and `education` and `none` carry nothing, since neither is capped. Alongside them
  sit `annualAdditions415c` and `compensationLimit401a17`, the pay ceiling a plan may count
  for any purpose including the match (§3.4.2)
- `contributionLimits[family].catchUpTiers`: ordered `{fromAge, toAge?, amount}` entries,
  the tier whose span contains `age(year)` supplying that year's catch-up. A list rather
  than a single amount and age because the enlarged 60-through-63 catch-up **reverts** at
  64 (§3.4.2)
- `contributionLimits.rothCatchUpWageThreshold`: prior-year FICA wages above which an
  `electiveDeferral` catch-up must be Roth regardless of the account's own treatment (§3.4.2)
- `rothIraIncomeLimit[filingStatus]`: the `{lower, upper}` MAGI range over which Roth IRA
  *contribution* eligibility phases out (§4.4.4 step 5)
- `iraDeductibilityPhaseOut[filingStatus][covered | spouseCoveredOnly]`: the `{lower,
  upper}` MAGI ranges over which a traditional IRA deduction phases out (§4.3.1)
- `earlyWithdrawalPenaltyRate` (0.10): applied to tax-deferred and unqualified Roth
  withdrawals before 59½ (§8.3, §8.4.1)
- `hsaNonMedicalPenaltyRate` (0.20): the steeper penalty on non-medical HSA withdrawals
  before 65 (§8.4.1), a different rate for a different account
- `rmdAgeByBirthYear`, keyed on `birthDate.year`
- `rmdDivisorTable[age]`: the IRS Uniform Lifetime Table divisor for each age, used to
  compute the required distribution amount each year (`openingBalance ÷ divisor`)

*Credits and health*

- `childTaxCreditPerChild`, `childTaxCreditPhaseOutThreshold[filingStatus]` **(fixed)**,
  `childTaxCreditPhaseOutPerThousand`, `childTaxCreditPhaseOutStep` (1000) **(fixed)** and
  `childTaxCreditQualifyingAge` (17): the credit, the age a child ages out of it, and the
  phase-out with the income step it is charged per (§4.3.4)
- `childTaxCreditRefundablePerChild`, `childTaxCreditRefundableRate`,
  `childTaxCreditRefundableEarnedIncomeFloor` **(fixed)**: the refundable-portion cap, the
  fraction of earned income above the floor that can be refunded, and that floor, which
  statute has never indexed (§4.3.4). Other federal credits are out of scope (§13.2).
- `federalPovertyLevel[stateCode][householdSize]`, where household size is **per TaxUnit**,
  meaning its persons plus its active dependents. Alaska and Hawaii carry their own much
  higher figures, and the ACA credit is a tax-family measure rather than a household one
  (§4.3.5)
- `acaApplicablePercentageTable`: ordered `{fplPercent, applicablePercent}` points,
  linearly interpolated **between** consecutive points. Two points sharing an `fplPercent`
  express a step, which a schedule with a discontinuity needs (§4.3.5)
- `acaMinimumFplPercent` (100) and `acaMaximumFplPercent` (nullable): the eligibility band
  for the premium tax credit. Below the minimum there is no credit at all, the household
  being Medicaid-eligible or in the coverage gap. Above the maximum, where one is set, the
  credit ends outright; a null maximum is the regime where it instead tapers to a fixed
  percentage of income and no cliff exists. The schedule has changed shape more than once,
  and interpolation alone cannot represent either edge (§4.3.5)
- `acaBenchmarkPremiumByAge`: national-average second-lowest-cost-silver-plan annual
  premium by age, the fallback when the user has not entered their local figure. Its index
  needs no extension rule: `covered` (§4.3.5) admits only persons under 65, and the published
  age curve starts at 0. It
  compounds at the `health` category's `defaultRelativeInflation` (§3.7)
- `irmaaBrackets[filingStatus]`: ordered `{magiThreshold, partBPremium, partDSurcharge}`
  tiers, monthly and per person, applied against MAGI from two years prior (§8.4.3)

*Sale of assets*

- `section121Exclusion[filingStatus]`: the primary-residence capital gain exclusion.
  Statutory and **(fixed)**, unchanged since 1997. Over a 30-year real-dollar projection it
  erodes substantially, which is exactly what happens to sellers (§7.4)
- `unrecapturedSection1250Rate` (0.25) and `residentialDepreciationYears` (27.5): the flat
  recapture rate and the straight-line schedule for `investmentProperty` (§3.5)

*State and local*

- `stateRules[stateCode]`: bracket table or flat rate, standard deduction and/or personal
  exemption, retirement-income exclusions, whether it conforms to federal treatment of
  pre-tax deferrals
- `localRules[localityCode]`

### 3.13 ProjectionSnapshot

A **frozen, timestamped copy of a projection's headline output**, persisted so a later run
can be compared against it. See §10 for why this exists and how it is triggered.

| Field                                                                           | Type                                                         | Notes                                                                                                                                                                                                                                                                               |
|---------------------------------------------------------------------------------|--------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                                                                            | ID                                                           |                                                                                                                                                                                                                                                                                     |
| `scenarioId`                                                                    | ID                                                           | Snapshots track one scenario's trajectory over time, not the whole household.                                                                                                                                                                                                       |
| `asOfDate`                                                                      | date                                                         | The real calendar date this snapshot was taken.                                                                                                                                                                                                                                     |
| `trigger`                                                                       | enum                                                         | `auto` \| `manual`. Only an `auto` row is deleted when a later same-day edit supersedes it (§10.1, invariant 19).                                                                                                                                                                   |
| `label`                                                                         | string?                                                      | User-supplied, for manual checkpoints ("Before the house purchase").                                                                                                                                                                                                                |
| `inputDigest`                                                                   | string                                                       | A cheap fingerprint of the household, the scenario, and the `AssetClass` rates at that moment, those being everything the output moves with. Used to skip writing a new auto-snapshot when nothing has actually changed.                                                            |
| `taxYearId`                                                                     | ID                                                           | Which bundled ruleset produced these figures. Two snapshots computed under different tax years are not cleanly comparable, and §10.2 has to be able to say so rather than reporting a bracket change as progress.                                                                   |
| `retirementYear`                                                                | {pessimistic, expected, optimistic: int \| `notReachable`}   | Frozen per-band result.                                                                                                                                                                                                                                                             |
| `fireNumber`                                                                    | {pessimistic, expected, optimistic: Money \| `notReachable`} | Per band, like `retirementYear` and for the same reason: §8.1 sizes it over `retirementDurationYears`, which each band's own solved retirement year fixes. A band with no qualifying year has no duration and so no target, and reports `notReachable` beside its `retirementYear`. |
| `netWorth` / `liquidNetWorth` / `investableNetWorth` / `afterTaxLiquidNetWorth` | Money                                                        | All four measures from §5, taken at `asOfDate` rather than projected, so they read the same in every band and §10.2 can report a delta on each.                                                                                                                                     |
| `sustainableLevelSpending`                                                      | {pessimistic, expected, optimistic: Money} | §5, read at the retirement year. The headline a household with a fixed retirement date tracks, where one solving for a date tracks `retirementYear` (§9.4). |
| `savingsRate`                                                                   | Rate                                                         | Taken at `asOfDate` like the net-worth measures, so it too reads the same in every band.                                                                                                                                                                                            |

A snapshot stores **outputs only**, which keeps it to a handful of scalars, so a daily
cadence over years of use is not a meaningful storage concern under local-only storage
(§1.4). The cost of that choice: a snapshot can tell you *that* the retirement year moved,
not *why* (§10, §13.1).

---

## 4. The annual cash-flow pipeline

Computed per projected year. Order matters: each tax must be computed against the correct
base.

### 4.1 Gross and payroll-tax wages

Per **Person**:

```
wageIncome      = Σ resolvedAmount(IncomeStream)   where kind in (w2Wages, bonus,
                                                                    rsuVesting)   // §3.3
seEarnings      = Σ resolvedAmount(IncomeStream)   where kind = selfEmployment
ficaExempt      = Σ resolvedAmount(Contribution)   where reducesFicaWages = true
                + Σ annualAmount(PayrollDeduction) where reducesFicaWages = true
ficaWages       = max(0, Σ resolvedAmount(IncomeStream) where isFicaSubject
                         − ficaExempt)
```

**FICA wages floor at zero.** §125 and §132(f) deductions can exceed FICA-subject pay, which
is ordinary for a part-time job carrying family coverage, and unfloored they would run `oasdi`
and `medicare` negative. The unused excess carries nowhere.

**`kind` places a stream for income tax; `isFicaSubject` decides only whether it pays
FICA.** They stay separate because the flag is overridable (§3.3) while the income terms
must remain a clean partition. Reading the flag in both places would count an overridden
`other` stream twice in §4.3.1 and drop an overridden `w2Wages` stream from income tax
entirely. The flag defaults true for `w2Wages`, `bonus`, and `rsuVesting`, and false for
everything else, including `selfEmployment`, which §4.2 handles on its own terms.

`ficaExempt` draws on both `Contribution` and `PayrollDeduction` (§3.4.5) because
cafeteria-plan items come in two shapes: an HSA deferral is money *saved* and belongs to an
`Account`, while a health premium or FSA election is money *spent* with no balance to
attach to. Both reduce FICA wages identically, so both reach this line.

### 4.2 Payroll taxes (per person, then summed)

```
oasdi              = TaxYear.oasdiRate    × min(ficaWages, TaxYear.socialSecurityWageBase)
medicare           = TaxYear.medicareRate × ficaWages                          // uncapped

seNetEarnings      = seEarnings × TaxYear.seNetEarningsFactor                  // 0.9235
seOasdiBase        = min(seNetEarnings, max(0, TaxYear.socialSecurityWageBase − ficaWages))
seOasdi            = 2 × TaxYear.oasdiRate    × seOasdiBase   // shares the cap with ficaWages
seMedicare         = 2 × TaxYear.medicareRate × seNetEarnings                  // uncapped
seTax              = seOasdi + seMedicare
seDeduction        = seTax / 2                                                 // above-the-line
```

**Every rate here comes from the active `TaxYear` (§3.12); none is a literal.** The
self-employment rates are *derived* as exactly twice the employee rates, which is the
meaning of "pays both halves" and removes any way for the two to drift apart across
tax-year updates.

**The SE OASDI cap is shared with W-2 wages, per person.** Someone with $150,000 of
`ficaWages` and $50,000 of `seNetEarnings` has only `socialSecurityWageBase − 150,000` of
remaining OASDI room for the SE income, since a second independent cap would overtax a
dual W-2-plus-side-income earner. This is on top of each **person** getting their own cap,
which is never a household-level figure.

Per **TaxUnit**, because the threshold is a filing-status figure applied to combined wages
*and* self-employment income:

```
addlMedicare    = TaxYear.additionalMedicareRate
                    × max(0, Σ (ficaWages + seNetEarnings)
                               − TaxYear.additionalMedicareThreshold[status])
```

`seDeduction` is half of `seTax` alone and correctly excludes `addlMedicare`: the
Additional Medicare Tax is not deductible, and it falls outside `seTax` structurally
because it is assessed per TaxUnit rather than per person.

### 4.3 Income taxes (per TaxUnit)

#### 4.3.1 Income and above-the-line deductions

Everything the tax unit received this year, less the deductions statute allows before AGI.
Every household reaches this part.

**Adjusted gross income (AGI)** is that figure, and the rate schedule and most phase-outs
are measured against it. A **modified AGI (MAGI)** is AGI with particular items added back,
and statute writes a different one for each rule that uses it, so no single MAGI exists here:
`preDeductionMagi` gates the two deductions below, `acaMagi` sizes the premium tax credit
(§4.3.5), and IRMAA reads a plain `federalAgi` from two years earlier (§8.4.3).

**Social Security taxability** (relevant once a person in the `TaxUnit` has reached
`claimingAge`, §3.11 and §8.4):

```
ssBenefits        = 0                                        if not Assumptions.includeSocialSecurity
                   = Σ over persons in this TaxUnit at or past claimingAge with includeInProjection:
                       12 × adjustedMonthlyBenefit                       // §3.11

rentalIncome      = Σ this TaxUnit's IncomeStreams, kind = rentalNet
taxableRental     = max(0, rentalIncome
                            − Σ annualDepreciation over this TaxUnit's held
                              investmentProperty Assets)
                                                                 // §3.5; cash flow keeps
                                                                 // the undepreciated figure
pensionIncome     = Σ this TaxUnit's IncomeStreams, kind = pension
otherStreamIncome = Σ this TaxUnit's IncomeStreams, kind = other
rmdIncome         = Σ rmd over this TaxUnit's persons and accounts   // §8.4.2, taken at the
                                                                     // top of the year

inAccountInvestmentIncome = Σ over this TaxUnit's Accounts, taxTreatment = taxable:
                              openingBalance × blendedIncomeYield   // §3.9, blended per §3.4's
                                                                    // allocationMode
qualifiedDividends        = Σ over those same accounts:
                              openingBalance × blendedIncomeYield
                                × blendedQualifiedIncomeFraction
ordinaryInAccountIncome   = inAccountInvestmentIncome − qualifiedDividends

realizedLongTermGains     = Σ over this TaxUnit's taxable Accounts:  // §6, surplus years
                              capitalGainsRealizationRate × max(0, balance − costBasis)
                          + Σ this TaxUnit's OneTimeEvents, taxTreatment = capitalGainLongTerm
                          + Σ taxable gain on this TaxUnit's Asset sales   // §3.5
                          + realized gains on any draw taken         // §8.4.1
realizedShortTermGains    = Σ this TaxUnit's OneTimeEvents, taxTreatment = capitalGainShortTerm
```

**Above-the-line deductions.**

```
studentLoanInterestPaid = Σ over this TaxUnit's Liabilities, kind = studentLoan
                            and isTaxDeductibleInterest:
                              this year's interest portion of the amortization
                              schedule (§3.6), deflated to real

preDeductionMagi        = nonSSIncome computed below, but *without* the two phased
                          deductions it gates: no deductibleStudentLoanInterest, and
                          traditional IRA contributions not yet subtracted

slLower, slUpper        = TaxYear.studentLoanInterestPhaseOut[status]
slPhasedFraction        = clamp((preDeductionMagi − slLower) / (slUpper − slLower), 0, 1)

deductibleStudentLoanInterest
                        = 0                                    if status = marriedFilingSeparately
                        = min(studentLoanInterestPaid,
                              TaxYear.studentLoanInterestCap)
                            × (1 − slPhasedFraction)           otherwise
```

**Traditional IRA deductibility is decided one year at a time.** A
`traditionalIra` `Contribution`'s `reducesFederalTaxableIncome` flag (§3.4.3) is the user's
*intent*; whether the deduction is allowed depends on that year's MAGI and on whether the
person or their spouse is covered by a workplace plan:

```
coveredByWorkplacePlan(person) = the person holds any Account with limitFamily =
                                 electiveDeferral, simpleDeferral or sep receiving a
                                 contribution or a match this year

iraLower, iraUpper = TaxYear.iraDeductibilityPhaseOut[status][covered | spouseCoveredOnly]
iraPhasedFraction  = clamp((preDeductionMagi − iraLower) / (iraUpper − iraLower), 0, 1)
deductibleIraPortion = 1 − iraPhasedFraction        // 1.0 when not covered at all
```

Both phase-outs run off `preDeductionMagi`, MAGI computed **before** the deductions they
gate. Statute specifies it that way, and it keeps the computation acyclic, since a
deduction whose size depended on income net of itself would need its own solve.

```
nonSSIncome       = Σ wageIncome over this TaxUnit's persons
                  + seEarnings − seDeduction
                  + taxableRental + pensionIncome + otherStreamIncome
                  + ordinaryInAccountIncome
                  + rmdIncome
                  + Σ this TaxUnit's OneTimeEvents, taxTreatment = ordinaryIncome
                  + realizedShortTermGains
                  + realizedLongTermGains + qualifiedDividends
                  − Σ resolvedAmount over this TaxUnit's Contributions,
                      reducesFederalTaxableIncome
                      (× deductibleIraPortion for traditionalIra contributions)
                  − Σ annualAmount over this TaxUnit's PayrollDeductions,
                      reducesFederalTaxableIncome
                  − deductibleStudentLoanInterest

half, cap        = TaxYear.socialSecurityTaxableFractions   // §3.12

provisionalIncome = nonSSIncome + half × ssBenefits   // tax-exempt interest omitted: not modeled (§13.2)

lower, upper      = TaxYear.socialSecurityTaxabilityThresholds[status]

taxableSS         = 0                                                                     if provisionalIncome ≤ lower
                   = min(half × ssBenefits, half × (provisionalIncome − lower))            if lower < provisionalIncome ≤ upper
                   = min(cap × ssBenefits,
                         cap × (provisionalIncome − upper)
                           + min(half × ssBenefits, half × (upper − lower)))               if provisionalIncome > upper
```

`marriedFilingSeparately` filers who lived with their spouse at any point in the year get
`lower = upper = 0`, so up to 85% of benefits is taxable regardless of income. The app does
not ask about cohabitation, so this threshold applies unconditionally for that filing
status, which is correct for the common case and conservative for the uncommon one.

**Only taxable accounts throw off currently-taxable income.** `inAccountInvestmentIncome`
sums over `taxTreatment = taxable` accounts alone, since distributions inside
`taxDeferred`, `roth`, `hsaTriple`, and `educationTaxFree` accounts are not taxed in the
year received, which is the entire point of those wrappers. The income is assumed
reinvested, staying in the account and compounding so no balance changes, while still being
taxed annually out of cash flow. **Because it is taxed, it also raises `costBasis`
(§6.3)**; without that step the same dollars would be taxed again as gains on the way out.

`rentalIncome` counts toward NIIT on the assumption of a passive landlord, which is the
typical case here. Rental activity rising to a trade or business the taxpayer materially
participates in would be excluded, and that distinction is not modeled.

#### 4.3.2 Taxable income and the §199A deduction

AGI less the standard or itemized deduction, then less the pass-through business deduction.
The §199A half applies only where someone has self-employment or rental income.

```
federalAgi      = nonSSIncome + taxableSS

age65Additional = TaxYear.additionalStandardDeductionAge65
                    × count of persons in this TaxUnit with age(year) ≥ 65
deduction       = max(TaxYear.standardDeduction[status] + age65Additional,
                      TaxUnit.itemizedDeductionTotal ?? 0)

taxableBeforeQbi = max(0, federalAgi − deduction)
```

`age65Additional` is **per qualifying person**, so a `marriedFilingJointly` couple both
past 65 receives it twice. The parallel addition for blindness is not modeled (§13.2).

**Qualified Business Income deduction (§199A).**

```
qbi             = Σ over this TaxUnit's streams where isQualifiedBusinessIncome, rental net of
                    depreciation (taxableRental, not rentalIncome)
                    − seDeduction attributable to those streams
                    − pre-tax retirement contributions funded from those streams
netCapitalGain  = realizedLongTermGains + qualifiedDividends

qbiDeduction    = min(TaxYear.qbiDeductionRate × max(0, qbi),
                      TaxYear.qbiDeductionRate × max(0, taxableBeforeQbi − netCapitalGain))

fedTaxable      = max(0, taxableBeforeQbi − qbiDeduction)
```

A deduction of up to 20% of pass-through business income, meaning Schedule C
self-employment and most rental real estate, taken **below the line** without itemizing.
For a household with meaningful `selfEmployment` or `rentalNet` income, omitting it
overstates tax by roughly a fifth of that income's marginal cost across an entire
accumulation phase.

Above `TaxYear.qbiThreshold[status]` the real deduction is limited by W-2 wages paid and
property basis, and phases out entirely for specified service businesses. **Neither limit
is modeled** (§13.2): above the threshold the engine applies the unlimited 20% and raises
`qbiLimitNotModeled`, which overstates the deduction for exactly the high-earning
professional the limits target.

#### 4.3.3 Brackets, capital gains, and NIIT

The rate schedule itself. Ordinary income and long-term gains are taxed on separate
schedules, and a surtax reaches investment income above a fixed threshold.

```
ordinaryPortion     = max(0, fedTaxable − realizedLongTermGains − qualifiedDividends)
preferentialPortion = fedTaxable − ordinaryPortion   // ≡ min(realizedLongTermGains +
                                                     // qualifiedDividends, fedTaxable); the two
                                                     // portions always sum to fedTaxable
ordinaryTax     = applyBrackets(ordinaryPortion, TaxYear.federalBrackets[status])
ltcgTax         = applyStackedBrackets(preferentialPortion,
                                       stackedOn = ordinaryPortion,
                                       TaxYear.federalLtcgBrackets[status])

netInvestmentIncome = inAccountInvestmentIncome + taxableRental
                    + realizedShortTermGains + realizedLongTermGains
                    + recapture   // §3.5; gain on a passive rental's sale is investment
                                  // income whichever rate it is taxed at
                      // pensionIncome and otherStreamIncome are excluded structurally, not by
                      // prose. Wages, self-employment earnings, Social Security, and traditional
                      // retirement-account distributions are likewise NOT investment
                      // income. But they do raise federalAgi, so they can push a household over the
                      // threshold and expose investment income that would otherwise escape it.

niitBase        = min(netInvestmentIncome, max(0, federalAgi − TaxYear.niitThreshold[status]))
niit            = TaxYear.niitRate × niitBase
recaptureTax    = TaxYear.unrecapturedSection1250Rate × recapture   // §3.5, asset sales

taxBeforeCredits   = ordinaryTax + ltcgTax + recaptureTax + niit
```

#### 4.3.4 The Child Tax Credit

Applies while a dependent is under `childTaxCreditQualifyingAge`. It is the one credit
modeled, and the only thing here that can make federal tax negative.

```
qualifyingChildren = count of dependents under TaxYear.childTaxCreditQualifyingAge
                       at the end of the tax year
earnedIncome       = Σ over persons in this TaxUnit (wageIncome + seNetEarnings)

ctcPhaseOut        = ceil(max(0, federalAgi − TaxYear.childTaxCreditPhaseOutThreshold[status])
                            / TaxYear.childTaxCreditPhaseOutStep)
                       × TaxYear.childTaxCreditPhaseOutPerThousand
ctcAfterPhaseOut   = max(0, qualifyingChildren × TaxYear.childTaxCreditPerChild − ctcPhaseOut)

nonRefundableCtc   = min(ctcAfterPhaseOut, max(0, taxBeforeCredits))
refundableCtc      = min(ctcAfterPhaseOut − nonRefundableCtc,
                         qualifyingChildren × TaxYear.childTaxCreditRefundablePerChild,
                         TaxYear.childTaxCreditRefundableRate
                           × max(0, earnedIncome − TaxYear.childTaxCreditRefundableEarnedIncomeFloor))
childTaxCredit     = nonRefundableCtc + refundableCtc

federalTax         = taxBeforeCredits − childTaxCredit
```

**The Child Tax Credit is only partly refundable.** The non-refundable portion cannot push
`federalTax` below zero, and beyond it the refundable portion is capped per child and
limited to a fraction of earned income above a floor, so `federalTax` goes negative only by
that bounded amount. Treating the CTC as one unlimited credit would materially overstate
the benefit in exactly the low-income years Coast and Barista FIRE scenarios (§9.2, §9.3)
are built around.

#### 4.3.5 The ACA premium tax credit

A household that retires before 65 buys its own health insurance, and the federal government
pays part of the premium on a sliding scale set by income against the federal poverty line.
An early retiree largely chooses their own income by choosing which accounts to draw from
(§8.4.4), so they largely choose the size of this subsidy. That is why it earns this much of
the section: it is the largest expense lever the plan has, and it turns on MAGI rather than
on the tax the rest of §4.3 computes.

**ACA premium tax credit** (per TaxUnit, only while a covered person is under 65):

```
acaMagi           = federalAgi + (ssBenefits − taxableSS)   // + tax-exempt interest, not modeled
taxUnitSize       = persons in this TaxUnit
                      + dependents active this year               // §3.2 supportEndYear
fplPercent        = 100 × acaMagi / TaxYear.federalPovertyLevel[stateCode][taxUnitSize]

covered           = persons in this TaxUnit with age(year) < 65
                      and year > employerHealthCoverageEndYear    // §3.1
benchmarkPremium  = 0                                            if covered is empty
                  = TaxUnit.benchmarkPremiumOverride             // this TaxUnit's own
                    ?? Σ over covered: TaxYear.acaBenchmarkPremiumByAge[age(year)]

eligible          = covered is non-empty
                    and fplPercent ≥ TaxYear.acaMinimumFplPercent
                    and (TaxYear.acaMaximumFplPercent is null
                         or fplPercent ≤ TaxYear.acaMaximumFplPercent)

applicablePercent = TaxYear.acaApplicablePercentageTable(fplPercent)   // interpolated
expectedContrib   = applicablePercent × acaMagi

premiumTaxCredit  = max(0, benchmarkPremium − expectedContrib)   if eligible
                  = 0                                            otherwise
```

**The credit has a floor as well as a ceiling, and the floor is the one this app walks
into.** Below `acaMinimumFplPercent` of the poverty line there is no premium tax credit at
all: the household is Medicaid-eligible in an expansion state, or in the coverage gap in
one that did not expand. §8.4.1 spends `cash`, `rothIraBasis` and `taxableBasis` first
precisely because they do not count toward MAGI, which drives MAGI *down*, and an unfloored
formula would reward that with a full-benchmark subsidy exactly where the real program pays
nothing. The engine raises **`acaMagiBelowSubsidyFloor`** in such a year rather than
silently zeroing the credit, because the household's real options there, realizing some
income deliberately or taking Medicaid, are a decision.

The ceiling is `acaMaximumFplPercent` and is nullable because the schedule's shape is not
settled law: under one regime the credit stops outright above a threshold, under another it
tapers to a fixed percentage of income with no cliff. A nullable maximum expresses both,
and `acaApplicablePercentageTable`'s repeated-`fplPercent` convention (§3.12) lets
the table carry a step where one exists.

**An empty `covered` set zeroes the premium before the override is consulted.** The fallback
does that by summing over nobody; an entered override does not, and `eligible` guards only the
credit, so without the gate a household would pay its silver premium every working year and
every year past 65 on top of what it actually pays.

**Employer coverage suppresses both sides.** A person still on an employer plan generates
no benchmark premium and no credit; their premium is a `PayrollDeduction` instead (§3.4.5),
and `covered` tests `Person.employerHealthCoverageEndYear`. Without a field behind
it, a Barista FIRE household carrying employer insurance (§9.2) would collect an ACA
subsidy on top of it.

**Without this, the whole MAGI apparatus is decorative.** `acaMagiCeilingPercentOfFpl` and
§8.4.4's withdrawal ordering exist to protect a subsidy, so if nothing computes the subsidy
the ceiling constrains withdrawals in exchange for nothing the model can see. Healthcare is
the largest single expense lever an early retiree controls.

The benchmark premium doubles as the household's actual premium, since the model has no
plan chosen to price instead. A household buying bronze pays less and one buying gold pays
more, and both keep the same credit, which is how the real program works.

The credit is applied in §4.4 as a **reduction to healthcare expense** rather than a tax
offset. That is how households experience it, through advance payments to the insurer, and
it keeps `federalTax` comparable to a real return.

#### 4.3.6 State, local, and the total owed

The state and locality layers, then everything above summed into one figure the pipeline
spends.

```
stateTax        = brackets or flat rate for this TaxUnit's filingStatus, from
                  TaxYear.stateRules[stateCode], applied to federalAgi adjusted by that
                  state's conformity flags, less its own standard deduction, personal
                  exemptions, and retirement-income exclusions, and zero in the states
                  that levy none
localTax        = the same shape against TaxYear.localRules[localityCode];
                  0 where localityCode is null
```

State and local follow the federal shape, reading the state's own conformity flags,
deduction, exemptions, and retirement-income exclusions. The conformity flags are what let
a state diverge on pre-tax deferrals (§3.4.3). Nine states levy no income tax, several are
flat, and localities such as NYC, Philadelphia, Ohio municipalities, and Maryland counties
add their own layer.

Schedules are held per filing status, because most states widen their brackets for a joint
return and reading a single filer's schedule for a couple overstates what they owe. A state
that publishes one schedule for everybody carries the same one under each status.

```
withdrawalPenalty = Σ over this TaxUnit's draws this year (§8.4.1):
                      TaxYear.earlyWithdrawalPenaltyRate × traditional and unqualified
                        rothEarnings drawn before 59½
                    + TaxYear.hsaNonMedicalPenaltyRate × hsaNonMedical drawn before 65

totalTaxOwed    = federalTax + stateTax + localTax
                + Σ over persons (oasdi + medicare + seTax) + addlMedicare
                + withdrawalPenalty
```

**The penalty is a charge on the amount drawn**, so it takes no
deduction and is added after credits. Leaving it out would price the bridge as free, which is
the one thing §8.3 and §8.4 exist to prevent.

Taxable income is computed **after the standard or itemized deduction**, since applying
brackets directly to gross income would materially overstate tax for every user. The
long-term capital gains schedule and NIIT are both included, the former being one of the
largest levers available to an early retiree, many of whom pay 0% on realized gains.

### 4.4 Surplus and where it goes

Per **Household**. Every sum below spans the whole household, unlike §4.3's, which are
per `TaxUnit`.

```
grossIncome     = Σ over persons (wageIncome + seEarnings)   // wages, salaries, profits
                + rentalIncome + pensionIncome + otherStreamIncome   // received as cash
                + Σ over taxUnits ssBenefits                 // the FULL benefit received,
                                                             // not just the taxable portion
                + Σ over taxUnits rmdIncome                                 // §8.4.2; forced, so it is cash
                                                             // in hand before the year is
                                                             // priced. Discretionary draws
                                                             // are sized from the deficit
                                                             // this leaves.
                                                             // NB: no in-account
                                                             // investment income; see below

payrollDeductions = Σ annualAmount(PayrollDeduction) active this year   // §3.4.5
committedContribs = Σ resolvedAmount(Contribution) active this year, whatever its
                    taxTreatment                                          // §3.4
expenseItemTotal  = Σ ExpenseItem active this year (see §3.7 for phase and lifetime)
debtService       = Σ over Liabilities active this year, meaning originated and not
                    yet paid off:
                      12 × (monthlyPayment + extraPrincipalPayment),
                      deflated to real for this year (§3.6)
                  + Σ over Liabilities already paid off:
                      12 × monthlyEscrow × escrowContinuesAfterPayoff     // §3.6
healthInsurance   = Σ over TaxUnits: max(0, benchmarkPremium − premiumTaxCredit)  // §4.3.5, pre-65
                  + Σ over persons with age(year) ≥ 65: medicareCost              // §8.4.3, IRMAA

annualExpenses    = expenseItemTotal + debtService + healthInsurance

oneTimeNet        = Σ OneTimeEvent.amount this year that no account absorbed   // §3.8:
                      inflows naming no accountId, plus the unfunded remainder
                      of an outflow whose account could not cover it
                  + any underwater balance from an Asset sale this year (§3.5)

education529Draw  = min(Σ over the household's Accounts where isRestrictedPurpose:
                          balance,                                             // §3.4
                        Σ ExpenseItem active this year whose category's
                          metaCategory is education)

netSurplus      = grossIncome
                + oneTimeNet                                   // signed; usually 0
                + education529Draw                             // tax-free; not in §4.3
                − payrollDeductions
                − committedContribs
                − totalTaxOwed
                − annualExpenses
```

**`annualExpenses` is the household's whole cost of living.** The `ExpenseItem` subtotal carries its
own name, `expenseItemTotal`.

**`healthInsurance` covers only the years the household buys its own coverage.** While a
person is on an employer plan, their premium is whatever the employer charges them and they
enter it as a `healthPremium` `PayrollDeduction` (§3.4.5); the engine adds nothing. Once
that coverage ends, §4.3.5 computes the benchmark premium and the credit against it, so a
user-entered premium would be priced against a subsidy that has nothing to do with it, and a
credit reaching `netSurplus` without its premium is a subsidy with no cost attached. The
net figure enters here and is booked to the `health` meta-category so §8.4.1's `hsaQualifiedMedical`
cap can see it.
Invariant 15 stops an `ExpenseItem` from restating it.

**Restricted education money is spent on what restricts it.** A `529` balance sits outside
`liquidNetWorth` and no `WithdrawalSource` can reach it (§3.4), so without this term it
would compound untouched while the tuition it was saved for came out of the retirement
accounts. The cap is that year's own education spending, mirroring how §8.4.1 caps
`hsaQualifiedMedical` at spending in the `health` meta-category. A qualified withdrawal is
tax-free, so nothing here reaches §4.3, and whatever the balance cannot cover falls through
to the ordinary sources.

**`committedContribs` covers every tax treatment, `taxable` included.** A standing
brokerage deposit is committed money like a 401(k) deferral is, and splitting the sum by
treatment would leave it inside `netSurplus` for the waterfall to allocate a second time.

**Debt service is a first-class term** for the reasons §3.6 gives, and the escrow that
outlives a payoff stays here rather than becoming an expense line, the same
obligation the servicer used to collect.

**`grossIncome` measures cash flow.** It is every form of earnings
the household actually receives this year before any deductions or taxes, and it differs
from `federalAgi` (§4.3.2) in both directions. It counts the *full* Social Security benefit
where AGI counts only the taxable slice, and it excludes two things that would otherwise be
counted twice:

- **Employer match is not gross income.** It never passes through the household's cash
  flow; §6 applies it straight to account balances after the pipeline runs. Counting it
  here would inflate both `netSurplus` and `savingsRate` with money the household never had
  to allocate, so `savingsRate` measures employee contributions only.
- **Investment income generated inside accounts is not gross income.** Neither realized
  gains nor distributions leave the account, and §6's growth step has already credited both
  to the balance, so treating either as inflow would let the waterfall re-invest dollars
  already sitting there. Both still generate tax, which flows through `totalTaxOwed` and
  reduces `netSurplus`, because the household really does pay that tax out of cash flow.

`rentalNet` enters as a net figure by construction (§3.3), a small departure from the
"before any deductions" the field otherwise holds.

Income received *outside* accounts (`rentalIncome`, `pensionIncome`, `otherStreamIncome`)
and investment income generated *inside* them (`inAccountInvestmentIncome`) stay separate
terms because their three consumers each want a different subset: `federalAgi` takes all of
it, NIIT takes the investment portion without pensions, and `grossIncome` takes the
externally-received portion without the in-account one.

#### 4.4.1 Committed contributions vs. the waterfall

The two funding mechanisms are **sequential**, and saying so has to
be explicit or they double-fund the same accounts:

1. **`Contribution` is the committed flow**, the payroll deferral or transfer the user has
   actually set up. It is authoritative, it happens first, and it is already subtracted
   from `netSurplus` above.
2. **The waterfall allocates only what remains.** Each step's capacity is that account's
   **remaining room**, its limit minus what the committed contribution already put in this
   year. A user contributing 10% to a 401(k) does not get that 10% subtracted and then the
   account topped up to the full elective limit again.

**Every retirement-account step needs earned income behind it.** Steps 1, 2, 5, 6 and 7
below can fund an account only for a person with `wageIncome + seEarnings > 0` that year,
since elective deferrals come out of pay and IRA and HSA contributions require
compensation. This matters in a retired year that turns positive on an RMD or a windfall,
where the surplus would otherwise be routed into an IRA the household cannot legally fund.
`highInterestDebt`, `cashBufferToTarget` and `taxableBrokerage` carry no such requirement.

#### 4.4.2 Funding windows

**Not every destination can accept money at the same time of year.** A 401(k) elective
deferral comes out of a paycheck, so once the year's paychecks are spent there is no way to
sweep December's leftover cash into it. An IRA or a direct HSA contribution can be funded after 
year's end, up to the filing deadline. A brokerage deposit or a debt payment can happen any time.

Each `WaterfallStep` therefore carries a `fundingWindow`:

| `fundingWindow`   | Steps                                                          | When it is resolved                   |
|-------------------|----------------------------------------------------------------|---------------------------------------|
| `payrollElection` | `matchCapture`, `hsaPayrollToLimit`, `electiveDeferralToLimit` | Before §4.1, from *projected* surplus |
| `filingDeadline`  | `iraToLimit`, `hsaDirectToLimit`                               | After §4.3, from *realized* surplus   |
| `anytime`         | `highInterestDebt`, `cashBufferToTarget`, `taxableBrokerage`   | After §4.3, from *realized* surplus   |

The user still configures **one ordered list**. The engine resolves it in two sweeps:

```
Sweep 1: election (before §4.1, on projected figures)
    reserve, at projected cost, every filingDeadline/anytime step the user ranked
      ABOVE a payrollElection step
    walk the list; fund only payrollElection steps from what remains
    the resolved amounts become this year's committed Contributions

§4.1 onward runs with those elections already known

Sweep 2: allocation (after §4.3, on realized figures)
    walk the list; fund filingDeadline and anytime steps from netSurplus
```

Sweep 1 lands before §4.1. Waiting until §4.3 would already be too late, since
`hsaPayrollToLimit` is the one step that reduces FICA wages, and an election settled later
misses `ficaExempt` and overstates payroll tax for the whole accumulation phase.

The two sweeps buy three things:

- **Deferrals behave like deferrals.** One is set in advance from an income estimate, the
  way a person sets a deferral rate, and it is capped by what that estimate supports.
- **The tax computation gets more accurate, and cheaper.** The largest pre-tax levers, the
  elective deferral and payroll HSA, are known *before* §4.3, so they reduce that year's
  taxable income in a single pass without iteration.
- **Over-electing behaves like over-electing.** If projected surplus was optimistic and the
  realized year cannot support the deferral, the year runs a `shortfall` and draws the cash
  buffer, raising `electionExceededRealizedSurplus`. That is the year a real
  household has after setting its deferral too high, and it is visible rather than quietly smoothed
  away.

Ranking an `anytime` step above a `payrollElection` step is how a user says "pay the credit
card before maxing the 401(k)", and the reservation in sweep 1 makes that ordering
mean something despite the timing difference.

#### 4.4.3 Solving taxes and the allocation together

Sweep 2 can still route money into `taxDeferred` destinations such as a deductible
traditional IRA or a direct HSA contribution, and those carry
`reducesFederalTaxableIncome`, changing the tax that determined how much surplus there was
to route. The engine solves that residue as a **bounded fixed point**:

```
pass 1: §4.3 with committed Contributions, sweep-1 elections, and PayrollDeductions
          → totalTaxOwed → netSurplus → run sweep 2
pass n: if the previous pass added pre-tax dollars in sweep 2, recompute §4.3 with
        them included → new totalTaxOwed → new netSurplus → re-run sweep 2
stop:   when the allocation stops moving, or after 3 passes, whichever comes first,
        flagging waterfallNotConverged in the latter case
```

Moving the deferral into sweep 1 shrinks this loop to the `filingDeadline` steps, capped at
the IRA and HSA limits, a few thousand dollars against a marginal rate. Each pass's
correction is roughly that rate times the previous delta, so it converges in two passes in
practice and three is a generous ceiling.

#### 4.4.4 The contribution waterfall

The *order* in which surplus is allocated changes the outcome, so it is routed through a
configurable **contribution waterfall**: `Assumptions.contributionWaterfall`, an ordered
list of `WaterfallStep` values (§3.9). The waterfall is a **household-level** list of step
*categories*, so each step sweeps every eligible account across every person in the
household simultaneously rather than exhausting one person's accounts before considering
another's.

`WaterfallStep` is a fixed vocabulary; the default order is all eight, in this sequence:

1. `matchCapture` *(payrollElection)*: raise each person's **employee** deferral to the
   minimum needed to capture their full employer match. This step moves employee dollars;
   the employer's own dollars are credited separately in §6 and are never surplus to
   allocate
2. `hsaPayrollToLimit` *(payrollElection)*: HSA via payroll to the limit for that person's
   active `hsaCoverage` tier, the triple tax advantage and the only contribution that also
   reduces FICA wages. **Skips any person aged 65 or older** (§3.4.2)
3. `highInterestDebt` *(anytime)*: principal paydown on every `Liability` whose real rate
   (§3.6) exceeds `Assumptions.highInterestDebtThresholdRate`, **highest real rate first
   (avalanche)**. Clearing a 22% card before a 7% student loan is strictly better, so this
   step overrides the pro-rata rule below
4. `cashBufferToTarget` *(anytime)*: every account with `targetBalanceMonths` set (§3.4),
   up to `targetBalanceMonths × annualExpenses / 12` each; skipped once at target (§4.5)
5. `iraToLimit` *(filingDeadline)*: the person's IRA limit, shared across traditional and
   Roth (§3.4.2). A Roth IRA contribution **stops at the Roth income limit**: above
   `TaxYear.rothIraIncomeLimit[status]`, measured against `preDeductionMagi` (§4.3.1), it
   contributes nothing and raises `rothIraIncomeLimitReached`, because the backdoor route
   that would make it legal is a conversion the engine cannot yet model (§13.3)
6. `electiveDeferralToLimit` *(payrollElection)*: remaining 401(k)/403(b)/TSP/SIMPLE to the
   elective deferral limit for that `limitFamily`
7. `hsaDirectToLimit` *(filingDeadline)*: any HSA room left after step 2, contributed
   directly. This route does **not** reduce FICA wages. Skips at 65 for the same reason as
   step 2
8. `taxableBrokerage` *(anytime)*: the remainder

A scenario's `contributionWaterfall` reorders or omits these steps. It cannot invent new
ones, and it cannot change a step's `fundingWindow`. **`taxableBrokerage` is the one step it
may not drop** (invariant 30), being what catches whatever the others leave; without it a
year's surplus would have nowhere to land.

**`sep` and `education` have no step, so surplus never reaches them.** For a `529` that is
right, sweeping into a restricted account lowering `liquidNetWorth`. For a SEP it is a real
cost: a self-employed household's surplus goes to `taxableBrokerage` while a deductible SEP
sits open, and that is the case to revisit if a ninth step is ever added.

Each step is capped by the limits for that account's `limitFamily` and `personId` (§3.4.2),
including catch-up. **If the surplus remaining when a step is reached cannot fully fund
every account in that step, it is split pro rata across those accounts by their remaining
room**, so two spouses' 401(k)s in step 6 split a shortfall proportionally. This keeps the
waterfall a single flat list without an explicit priority order between people, while still
respecting each person's individual limits.

**If `netSurplus` is negative**, the gap is sourced through `withdrawalOrder` (§8.4.1), the
same machinery retirement uses, and the year is flagged `shortfall`. Drawing a cash buffer
below its target raises `bufferDepleted`. `payrollElection` steps are never unwound, since
a deferral already withheld from a paycheck cannot be undone at year end, and that is
precisely why over-electing hurts.

### 4.5 The cash buffer

An emergency fund is a **target balance**. Modeling it as a perpetual
annual contribution would drain decades of surplus that should have been invested, since it
never stops taking new money.

Modeled as an `Account` (typically `cashSavings`) with `targetBalanceMonths` set, which
fixes that year's Money target (§3.4). The `cashBufferToTarget` waterfall step (§4.4.4) tops
it up until `balance` reaches that target, then skips it, so the buffer stops
competing with Roth and 401(k) contributions once funded. It refills automatically after a
shortfall year draws it down, since the step re-evaluates the gap every year.

In decumulation the same target becomes a floor: the `cash` withdrawal source (§8.4.1) draws
the balance down to it, and below it only when every other source is exhausted.

## 5. Derived quantities

| Quantity                            | Definition                                                                                                                                                                                                                                                       |
|-------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `netWorth`                          | Σ Account.balance + Σ currentValue over Assets held this year (§3.5) − Σ currentBalance over Liabilities already originated                                                                                                                                      |
| `liquidNetWorth`                    | Σ Account.balance where **not** `isRestrictedPurpose` − Σ unsecured Liability.currentBalance. Accounts only, and unsecured debt only once originated; an `Asset` reaches this measure only after a sale deposits its proceeds (§3.5).                            |
| `investableNetWorth`                | `liquidNetWorth` less each cash-buffer account's target amount, not the account itself, so a buffer holding more than its target leaves the excess here (§4.5). **Display only**, read by no engine decision.                                                    |
| `afterTaxLiquidNetWorth`            | `liquidNetWorth` − estimated tax on unrealized gains and on future tax-deferred withdrawals (§8.2)                                                                                                                                                               |
| `annualExpenses`                    | Per §4.4: `expenseItemTotal + debtService + healthInsurance`. One definition, used by the cash-buffer target (§4.5), `retirementAnnualExpenses`, and the FIRE number (§8.1).                                                                                     |
| `expenseItemTotal`                  | Σ active `ExpenseItem`s for the year, at the year's `phase` (§3.7). The `ExpenseItem` subtotal alone, never the household's full cost of living.                                                                                                                 |
| `retirementAnnualExpenses`          | `annualExpenses` evaluated at the **first** year of retirement, `phase` post-retirement, at `postRetirementAmount` where set, including debt still outstanding and the share of escrow that continues past payoff (§3.6). Reported, and not what sizes the plan. |
| `levelEquivalentRetirementExpenses` | The constant annual spend with the same present value, at `safeWithdrawalRate`, as the whole projected retirement stream (§8.1). This is the FIRE number's input. Equal to `retirementAnnualExpenses` when retirement spending is flat.                          |
| `savingsRate`                       | (committedContribs + Σ 12 × extraPrincipalPayment over active Liabilities + netSurplus) / grossIncome                                                                                                                                                            |
| `retirementYear`                    | Per `Person`, §3.1: their `plannedRetirementAge` applied to `birthDate`, else the household's. For the household, the year §8.2 solves for.                                                                                                                      |
| `retirementDurationYears`           | `projectionHorizonAge` − the youngest person's age at the retirement year. During §8.2's search that is the **candidate** year under test, since it feeds both the FIRE number that year is tested against (§8.1) and the `swrHorizonMismatch` check.            |
| `fireNumber`                        | §8.1                                                                                                                                                                                                                             |
| `sustainableLevelSpending`          | `afterTaxLiquidNetWorth` projected to the first year of retirement × `safeWithdrawalRate`. The inverse of `fireNumber`: what the plan as entered will support, rather than what a chosen standard of living demands (§9.4). `notReachable` where `retirementYear` is. |
| `spendingHeadroom`                  | `sustainableLevelSpending` − `levelEquivalentRetirementExpenses`. Positive is room to spend more, negative is the annual gap (§9.4). `notReachable` where either side is.                                                                                                                                                                                                                                                             |

**`savingsRate` measures employee contributions only**, excluding employer match (§4.4.1),
which is deliberate and conservative. Principal paydown counts as saving whichever route it
takes, the user's own `extraPrincipalPayment` or the `highInterestDebt` waterfall step,
since both raise net worth by the same dollar. The first is added back because §4.4 already
subtracted it inside `debtService`.

## 6. The projection engine

Every run takes an `asOfDate`, defaulting to today when run live. `currentYear` is
`asOfDate.year`; `yearFraction(0)` is the remaining fraction of that calendar year from
`asOfDate` to December 31, and `1.0` for every later year.

```
horizon = the year the youngest Person reaches projectionHorizonAge

for year in currentYear .. horizon:
    frac = yearFraction(year)                    // < 1.0 only for year 0
    for each Person:
        age(year), income streams active this year, realGrowthRate compounded
    inflate each active ExpenseItem by its relative inflation rate (§3.7)
    accrue depreciation on any held investmentProperty (§3.5)
    settle this year's OneTimeEvents, and any Asset whose acquisitionYear or
      plannedSaleYear is this year, fixing the money and gains they move (§3.5, §3.8)
    take required minimum distributions for anyone past their RMD age; they
      arrive as ordinary income and cash like any other inflow (§8.4.2)
    draw education529Draw from the restricted education balances it came from,
      that year's education spending having sized it (§4.4)

    resolve sweep 1's payroll elections, then run §4.1 onward and solve the
      §4.3 ⇄ §4.4.3 fixed point on FULL-YEAR figures
        → taxes, committed contributions, surplus
    scale that year's recurring cash flows and the tax on them × frac  // 1.0 after year 0;
      oneTimeNet and the tax on it are not scaled, being dated to the year (below)
    apply committed contributions and their employer match to balances

    if netSurplus ≥ 0:
        run the contribution waterfall (§4.4.4) against balances and principal
        realize gains per capitalGainsRealizationRate
    else:
        solve the draw ⇄ §4.3 fixed point: source the gap through withdrawalOrder
          under the active MAGI ceiling, tax and penalize the result, and
          re-source both; realize gains on the taxable portion of what was drawn

    grow each Account on the mid-year convention (below), at its allocation's real
      return for the active band
    grow each Asset held this year by (1 + realAppreciationRate)^frac
    amortize each Liability, applying any highInterestDebt paydown (§4.4.4) to principal
      first; drop PMI at its LTV threshold; at payoff retire it
      and carry continuing escrow forward (§3.6)
    maintain cost basis and Roth contribution basis (below)
    append this TaxUnit's federalAgi to its two-year MAGI history (IRMAA, §8.4.3)
    recompute netWorth, liquidNetWorth, investableNetWorth, afterTaxLiquidNetWorth
    emit YearResult
```

**There is one loop, and the sign of `netSurplus` decides how it ends.** A working year has
money to allocate and a retired year has a gap to fill. Nothing else about the year differs,
so growth, asset sales, amortization, basis, and the net-worth measures are written once. It
also means a Barista FIRE year holding both wages and withdrawals needs no special case
(§9.2), and neither does a working year that runs short.

The drawdown carries a fixed point of its own: a `traditional` draw is ordinary income, that
income is taxed, and the tax has to be drawn as well, which raises the draw again. It
converges the same bounded way as §4.4.3's.

### 6.1 Solving for the retirement year

The projection cannot run until it knows when earned income stops, and it stops at the
retirement year §8.2 is solving for. The loop above is therefore run at two levels.

**Baseline pass: everybody keeps working.** Every earned `IncomeStream` runs to its explicit
`endYear`, or to the end of the horizon where none was set. A `Person` with
`plannedRetirementAge` set is not part of the circularity at all: their `retirementYear` is
known up front, their streams end there, and the baseline honors it.

**Candidate evaluation, at each year `Y` of the baseline pass.** Legs 1 and 2 of §8.2 read
the baseline's balances at `Y` directly. Leg 3 forks a counterfactual branch in which
`retirementYear = Y`, so every earned stream still running, every committed contribution,
and any defaulted employer coverage all end at `Y − 1`, `ExpenseItem.phase` flips, and the
branch runs to `projectionHorizonAge`.

**Final pass, once `retirementYear` is fixed.** The loop is re-run with the solved year
applied, so the emitted `YearResult`s and every net-worth measure describe a household that
actually stops working. That is the projection the UI shows; the baseline pass is scaffolding
and is never displayed.

Leg 3 is the expensive one, a full multi-decade simulation per candidate year and per band,
so it is evaluated **only for years where legs 1 and 2 already pass**. Those legs are cheap
reads on balances the baseline has already produced, and they fail for most of the horizon,
which bounds the fork to the handful of years near the crossing.

### 6.2 The mid-year convention

Contributions arrive across the year. Growing the closing balance as though they had all
landed on January 1 hands every December dollar a full year of compounding it never earned,
overstating each contribution by about 2.5% at a 5% real return, on every contribution, for
the whole accumulation phase. That is a systematic optimism that lands directly on the
retirement date.

So each account's flows earn half a year:

```
openingBalance = balance at the start of the year
netFlows       = contributions + employer match + deposits − withdrawals − outflows
r              = the band's real return for this account's allocation: its
                 `assetAllocationId`, or the `allocationWeights` blend, per `allocationMode`

closingBalance = openingBalance × (1 + r)^frac  +  netFlows × (1 + r)^(frac / 2)
```

The same convention applies to withdrawals in decumulation, where it cuts the other way:
money spent in July should not be charged a full year of forgone growth.

**This is not a move to monthly steps.** §1.2's annual granularity holds. `(1 + r)^0.5` is
the closed form for flows spread uniformly through the year, within a hundredth of a percent
of a twelve-step loop at ordinary return rates, at the cost of one exponent.

### 6.3 Basis maintenance

**Basis is engine state.** The user enters an opening `costBasis` and
`rothContributionBasis`; from there the engine maintains both every year. Leaving them frozen
breaks three separate things: reinvested distributions get taxed twice,
`capitalGainsRealizationRate` re-realizes the same gains forever, and §8.3's bridge test fires
on plans that are comfortably funded.

For each **taxable** `Account`:

```
costBasis += after-tax dollars deposited this year            // committed Contributions,
                                                              // waterfall allocations,
                                                              // OneTimeEvent inflows (§3.8)
                                                              // and Asset sale proceeds (§3.5)
costBasis += inAccountInvestmentIncome for this account       // distributions, taxed
                                                              // this year (§4.3.1) and
                                                              // reinvested (§3.9)
costBasis += realizedGain this year                           // already taxed
costBasis −= costBasis × (outflow / balance before it)        // pro rata at the ratio
                                                              // the draw actually saw, not
                                                              // the post-growth closing one
```

**A deposit of already-taxed dollars brings its basis with it**, or the whole of an
inheritance reads as gain on the way out. Stepped-up basis at death makes the deposited figure
right there too.

**The denominator is the balance the outflow was taken from**, not the closing balance
maintenance actually runs against: $40,000 out of $100,000 is 40% of the basis, not the 67%
a $60,000 closing balance would imply.

Appreciation never changes basis, which is the entire point of it. Realized gains are:

```
unrealizedGain  = max(0, balance − costBasis)
realizedGain    = capitalGainsRealizationRate × unrealizedGain     // surplus years only
```

and feed `realizedLongTermGains` in §4.3. **Ordinary realization only ever produces
long-term gains**; `realizedShortTermGains` arises solely from a `OneTimeEvent` with
`taxTreatment = capitalGainShortTerm`. The `max(0, …)` means the engine never generates a
capital loss from rebalancing, which is why loss carryforwards are deferred (§13.2).

For each **Roth** `Account`:

```
rothContributionBasis += employee contributions credited this year   // not growth,
                                                                     // not employer match
rothContributionBasis −= amount drawn as the rothIraBasis source (§8.4.1)
rothContributionBasis moves with its balance on the §8.4.1 rollover, out of the
                      designated Roth account and into the receiving rothIra
```

Employer match to a Roth 401(k) raises `balance` and leaves `rothContributionBasis` alone,
since matched dollars are not employee contributions and do not carry the same penalty-free
withdrawal treatment.

### 6.4 Why the pipeline runs on full-year figures

**Proration applies to the annual cash-flow pipeline's results (§4), never to its inputs.** The
pipeline always runs on full annual figures, and `frac` scales what comes out. Running it on
prorated inputs would tax a partial year as though it were a whole one: five months of
a $200,000 salary is $83,000, and $83,000 through progressive brackets yields a far lower effective
rate than the household actually pays. The Social Security wage base breaks the same way, since a
projection run in August must not hand a high earner a fresh, unconsumed wage base for the remaining
months.

Computing the full year and then taking `frac` of the result gives the household's true
effective rate applied to the part of the year that has not happened yet. The earlier months
are excluded rather than recomputed, since the balances the user entered already
reflect them.

An `ExpenseItem`, `IncomeStream`, `Contribution`, or `PayrollDeduction` whose own span only
partially overlaps year 0 is prorated against that overlap rather than against
`yearFraction(0)`. All four carry `startMonth`/`endMonth` (§3.3), so a stream starting in
October of year 0 counts for its 3 months and not `frac`'s share of 12.

**An `OneTimeEvent`, an `acquisitionYear`, or a `plannedSaleYear` in `currentYear` fires in
full, and `frac` does not scale it.** None carries a month, so the engine cannot tell whether
it has happened yet and treats it as still ahead. One that has already happened is by then inside the entered balances and would
be counted twice. The UI should say so wherever an event is dated this year.

`YearResult` carries: year, per-person ages, gross income, per-person `ficaWages` (§3.4
reads the prior year's), tax breakdown by type, the withdrawal penalty separately from tax,
contributions by account, expenses by category, debt service, surplus, all four net-worth
measures, the FIRE number for that year, and a `flags[]` array (`shortfall`,
`contributionLimitExceeded`, `bufferDepleted`, `bridgeGapDetected`, `waterfallNotConverged`,
`electionExceededRealizedSurplus`, `rothIraIncomeLimitReached`, `magiCeilingBreached`,
`acaMagiBelowSubsidyFloor`, `payoffLeavesResidualEscrow`, `swrHorizonMismatch`,
`qbiLimitNotModeled`, `unvestedMatchAtRisk`, `possibleDoubleCount`,
`derivedPayoffDiffersFromTerm`, `filingStatusNoLongerQualifies`,
`hsaContributionsStoppedAtMedicare`, `rothRolloverAssumed`, `retirementSpendingNotLevel`,
`earningsTestNotModeled`,
`escrowDiffersFromInferred`).

A run produces three `ProjectionResult`s per scenario, one per return band, each carrying
that band's ordered `YearResult`s and its solved `retirementYear`. A run may also
write a `ProjectionSnapshot` per §10. The live numbers a user sees are always a fresh
recompute from current state, and the snapshot lets a later run be compared against
this one.

## 7. Tax-rule versioning

### 7.1 Which year's rules

A projection runs under `Assumptions.taxYearId`, defaulting to the newest bundled `TaxYear`.

### 7.2 Future years

Current law is held constant in real terms (§1.1): brackets, deductions, and limits are
treated as indexed, so they do not drift against real income. The exceptions are the
thresholds statute has never adjusted, which §7.4 lists and the engine deflates instead, and
they include a deduction ceiling and a credit threshold, so the categories here are not a
safe guide on their own.

### 7.3 Scheduled statutory changes

Where a change is already law with a known effective date, the `TaxYear` records it and the
engine applies it from that year forward.

### 7.4 Non-indexed thresholds

Some thresholds statute indexes; others are fixed nominal figures that have never moved and
must therefore be **deflated** each projected year by `generalInflationRate` (§1.1).
Otherwise an increasing share of users silently stops crossing them, when crossing them is
the real-world effect. The engine reads the `indexed` flag on each `TaxYear` datum (§3.12).
The fixed set, and what ignoring each would cost:

| Threshold                                   | Effect of ignoring it                                                                                          |
|---------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `additionalMedicareThreshold`               | Understates payroll tax for high earners, increasingly with horizon                                            |
| `niitThreshold`                             | Understates investment tax; compounds with a growing portfolio                                                 |
| `socialSecurityTaxabilityThresholds`        | Understates taxable benefits; most retirees cross these eventually                                             |
| `section121Exclusion`                       | Overstates the shelter on a home sale, growing with the holding period; material to any downsizing plan (§3.5) |
| `studentLoanInterestCap`                    | Overstates the deduction, though it is small and short-lived                                                   |
| `childTaxCreditPhaseOutThreshold`           | Overstates the credit for households near the phase-out                                                        |
| `childTaxCreditRefundableEarnedIncomeFloor` | Overstates the refundable credit in low-income years, which is the Coast and Barista FIRE shape (§9.2, §9.3)   |

The `studentLoanInterest` pair is why the flag has to sit on individual thresholds rather
than on groups of them: the $2,500 ceiling is fixed while the MAGI range it phases out over
is indexed, so a single `TaxYear` entry needs both treatments at once.

### 7.5 Stale data

If the calendar year exceeds the newest bundled `TaxYear`, the app projects under the newest
available ruleset and displays a persistent, non-dismissible notice naming the tax year in
use. It must never silently imply currency it does not have.

### 7.6 State and territory coverage

`TaxYear.stateRules` covers **all 50 states and the District of Columbia** at launch. This
is the largest recurring data-maintenance commitment in the app (§1.4). Each state's rules
are pulled from that state's Department of Revenue publications for the tax year, normalized
into the shared `stateRules[stateCode]` shape, and versioned alongside the rest of that
year's `TaxYear`. Rules change annually, so extraction runs once per tax year, and a human
reviews the result before a `TaxYear` ships, since DoR sites are not uniform and bracket
figures need a sanity check against the prior year.

**US territories (Puerto Rico, Guam, USVI, American Samoa, Northern Mariana Islands) are a
materially different problem and are excluded from launch scope.** Puerto Rico in particular
runs a tax code that is largely a separate system with its own AGI definition rather than a
"mirror" of the federal one layered with state-style brackets. Folding it into
`stateRules[stateCode]`'s shape would misrepresent how the tax actually works.

---

## 8. Retirement determination

### 8.1 FIRE number

```
N       = retirementDurationYears (§5)
r       = safeWithdrawalRate
S(t)    = projected retirement spending in year t, for t = 0 .. N−1

pv      = Σ S(t) / (1 + r)^t
annuity = Σ 1    / (1 + r)^t   ≡  (1 + r) × (1 − (1 + r)^−N) / r

levelEquivalentRetirementExpenses = pv / annuity
fireNumber                        = levelEquivalentRetirementExpenses / r
```

**Both sums run over the same `t`, and the `(1 + r)` is what makes the closed form agree
with that.** Spending starts at retirement rather than a year after it, so `t` begins at 0,
and the textbook factor `(1 − (1 + r)^−N) / r` sums from 1. Either range gives the same
`fireNumber`, since `pv / annuity` cancels the difference. Mixing them does not cancel:
pricing the worked household below with a `t = 0` numerator against the textbook
denominator gives $85,109 where the answer is $82,231.

`safeWithdrawalRate` is a **real** rate, consistent with §1.1, and strictly positive over a
horizon of at least one year, since it and the annuity are both denominators here
(invariant 28). The input is **retirement**
spending (§3.7), including debt service still outstanding in retirement plus any escrow
costs that continue past a mortgage payoff (§3.6).

**Retirement spending is a stream, and the FIRE number prices the stream.** `S(t)` is
`annualExpenses` (§4.4) projected across retirement: every `ExpenseItem` at its
post-retirement `phase`, compounded at its relative inflation rate (§3.7) and honoring its
own `startYear`/`endYear`, debt service running until each loan's derived payoff and then
dropping to whatever escrow continues (§3.6), and health insurance following its ACA →
Medicare schedule at 65 (§8.4.3).

Sizing the portfolio off the *first* year of that stream would charge the household for a
mortgage payment for the rest of their life when the mortgage retires in 2041, and §3.6
promises the opposite. Levelling the stream keeps that promise. A household whose
retirement spending genuinely is flat gets `pv / annuity = S(0)` and the familiar `spending
/ SWR`, unchanged, so the machinery only moves the number when spending actually moves.

`pv / annuity` is a weighted average of the stream, near years counting for more. The
discount rate is `safeWithdrawalRate` itself, which keeps the conversion self-consistent,
since `fireNumber = W / r` is already the present value of a level `W` at `r`. It also keeps
one headline number across all three bands, which a band-dependent rate would not.

**`retirementAnnualExpenses` is reported, and it does not size the plan.** It is the first
year of the stream, the figure a user recognizes as "what I'll spend in retirement." When it
and `levelEquivalentRetirementExpenses` diverge by more than a trivial amount the engine
raises **`retirementSpendingNotLevel`**, so the UI can say why the plan is sized below the
first year's spending.

A worked check for an implementation. A household retiring on $70,000 of base spending plus
a $22,000 mortgage that runs ten more years, leaving $6,000 of continuing escrow, over a
40-year horizon at a 3.5% SWR: the first year is $92,000, the level equivalent is $82,231,
and the FIRE number is $2.35M rather than $2.63M. The size of the reduction tracks *when*
the expense ends. Same household, varying only the payoff: three years into retirement takes
$397,000 off the FIRE number, twenty-five years in takes $104,000, and flat spending takes
off nothing at all and reproduces `retirementAnnualExpenses / safeWithdrawalRate` exactly.

**The health component carries the same circularity §8.2 already resolves.** The ACA credit
inside `S(t)` depends on MAGI, MAGI depends on withdrawals, and withdrawals depend on the
spending being priced. The engine breaks it in one direction: §8.2's one-year draw is
sourced against retirement spending *excluding* health, that draw sets MAGI, MAGI sets the
credit, and the credit completes `S(t)`. The structure holds across the pre-65 years and
switches to Medicare plus IRMAA at 65. Cheap estimate up front, leg 3 verifies, the same
division of labor as the tax rates.

Computing the stream is `O(N)` of expense arithmetic per candidate year, nearly
band-independent since only the health estimate differs. Its one cost beyond that is the
single-year draw §8.2 already runs to derive its tax rates, which the health term reads
rather than repeats, so the FIRE number adds no solve and no simulation of its own.

**Retirement length enters through `safeWithdrawalRate`, and nowhere else.** The multiple is
`1 / safeWithdrawalRate`, so 4% gives 25× and 3.25% gives ~31×. Nothing is
hardcoded. The default deserves a warning label, because **4% is a 30-year figure**. That is
the horizon the Trinity study tested, and the number entered FIRE folklore stripped of it. A
40-year-old planning a 55-year retirement who leaves the default in place is using a rule
calibrated to roughly half their horizon.

Longer horizons need a lower rate, and the difference is not marginal: at $80,000 of
spending, 4% asks for $2.0M and 3.25% asks for $2.46M. As rough guidance the UI surfaces,
freely overridden and never engine constants:

| Retirement duration | Commonly cited real SWR                      |
|---------------------|----------------------------------------------|
| ~30 years           | 4.0%                                         |
| ~40 years           | 3.5%                                         |
| 50+ years           | 3.0–3.25% (approaching perpetual withdrawal) |

The engine derives `retirementDurationYears` (§5) and raises `swrHorizonMismatch` when the
chosen rate is optimistic for the implied duration, such as 4% against a 50-year horizon. It
warns rather than overriding, since the SWR is a judgment call about sequence risk,
valuations, and flexibility, and picking it for the user would hide the single most
consequential assumption in the model behind a lookup table.

**`retirementDurationYears` has one job here, and it is not the multiple.** It sets the
window the spending stream is levelled over, deciding which years get averaged. Letting it
into both would count the horizon twice. The **decumulation simulation (§8.2 leg 3) is where
duration is actually tested**, year by year against `projectionHorizonAge`. A user who sets
an over-optimistic SWR gets a cheerful FIRE number and a failing leg 3, which is the right
way round.

**The tax on withdrawals is modeled exactly once, on the balance side.** Both the FIRE
number and the balance it is compared against (§8.2) are denominated in **after-tax**
dollars. Grossing the spending up for withdrawal tax *and* comparing it against a
tax-adjusted balance would apply the same haircut twice and push the retirement year out by
years.

The balance side is the right place for it: §8.2 already holds each account's tax character,
where a spending-side gross-up would collapse all of it into one blended rate. It also makes
the headline the figure users recognize, 25× retirement spending at the default rate.

**Guaranteed income is deliberately excluded.** `fireNumber` sizes a portfolio that funds
*all* of retirement spending from withdrawals, ignoring Social Security and pensions even
though the decumulation simulation (§8.2 leg 3) counts both. That suits this app's audience:
an early retiree's binding constraint is the decades *before* those benefits arrive (§8.3),
and Social Security carries both political risk and the earnings-record haircut §3.11
describes.

The cost is real and runs one way. Because leg 1 is a hard gate, a household retiring at or
after `claimingAge`, where guaranteed income genuinely does cover a large share of spending,
can be told a year does not qualify even when legs 2 and 3 both clear it. For a FIRE
calculator that is the right direction to err, and the UI must show the guaranteed income
the simulation is counting so the gap between the conservative headline and the passing
simulation is legible.

### 8.2 The retirement test

A year qualifies when **all three** hold:

1. `afterTaxLiquidNetWorth ≥ fireNumber`
2. The bridge period is funded (§8.3)
3. The decumulation simulation survives to `projectionHorizonAge`

`projectionHorizonAge` is evaluated against the **youngest** `Person` in the household, so
the portfolio has to outlast whoever will need it longest.

`afterTaxLiquidNetWorth` subtracts the tax embedded in each balance:

```
taxableEmbedded  = Σ over taxable Accounts:
                     max(0, balance − costBasis) × projectedLtcgRate
deferredEmbedded = Σ over taxDeferred and hsaTriple Accounts:
                     balance × effectiveRetirementTaxRate
                                        // roth balances are subtracted at zero;
                                        // restricted accounts are already out of
                                        // liquidNetWorth (§5)

afterTaxLiquidNetWorth = liquidNetWorth − taxableEmbedded − deferredEmbedded
```

An HSA is priced as tax-deferred, since only the part eventually spent on qualified medical
costs escapes tax and the model cannot know how much that will be. This understates the
best-treated account in the plan, which is the safe direction for a figure that gates a
retirement date.

**Deriving `effectiveRetirementTaxRate` and `projectedLtcgRate` without a full iterative
solve.** The naive approach, guessing a FIRE number and running the whole multi-decade
decumulation simulation against it until it converges, is accurate and expensive: it reruns
years of simulation at every candidate year of the outer projection loop.

Instead, both rates are computed **directly from that year's actual account balances**, in
one pass. At each candidate year in the projection loop (§6.1) the engine already knows the
real balance in every account by `taxTreatment`. It applies the configured `withdrawalOrder`
to source exactly one year of `retirementAnnualExpenses` from those balances, runs that
single withdrawal through the real §4.3 tax computation, and reads off two figures: the
effective ordinary rate on the `traditional` portion, and the marginal LTCG rate on the gain
portion of the `taxable` draw.

The tradeoff: this prices the *first* year of retirement accurately and does not capture how
the tax picture shifts decades in, with RMDs forcing more ordinary income later. That gap is
covered by the test's third leg, since the full decumulation simulation still runs to verify
`projectionHorizonAge` survival, so an over-optimistic one-year estimate is caught there and
the year does not qualify.

`retirementYear` is the first qualifying year. **If no year qualifies within the horizon,
the result is explicitly `notReachable`**, and so is that band's `fireNumber`, which has no
duration to be sized over. The shortfall reported is `afterTaxLiquidNetWorth` at the horizon
against the FIRE number of the last candidate year evaluated. Never a blank
and never an arbitrarily distant year.

### 8.3 The bridge period

The gap between retiring and turning 59½, during which tax-deferred money is penalized.

**What the engine models.** A `traditional` or unqualified `rothEarnings` withdrawal before
59½ incurs `TaxYear.earlyWithdrawalPenaltyRate` on top of ordinary income tax (§8.4.1).
Bridge-eligible assets are the sources that escape that penalty: `cash`, `taxable` in full
(a brokerage account has no age gate, and its gain portion is taxed and never penalized),
`rothIraBasis` (withdrawable at any age, tax- and penalty-free), and `hsaQualifiedMedical`
to the extent of that year's actual medical spending.

A designated Roth balance is bridge-eligible only from the year §8.4.1's assumed rollover moves it
into a Roth IRA. Before that it is `rothEarnings`, taxed and penalized, because a designated
Roth account has no contributions-first ordering rule to draw against.

If total bridge-eligible assets are less than cumulative spending across the bridge, the year
is flagged `bridgeGapDetected` and does not qualify even where the raw number clears the FIRE
target. The comparison ignores both the growth those assets earn and any pension, rental, or
part-time income arriving during the bridge, so it screens conservatively and leg 3 settles
the year.

**Bridge eligibility depends on basis being maintained across the projection.** A household that
has been contributing to a Roth IRA for fifteen years has fifteen years of withdrawable
`rothContributionBasis`, and the engine must accrue it across the accumulation phase (§6.3).
Freezing it at the value the user typed in makes `bridgeGapDetected` fire on plans that are
comfortably funded.

**What it does not model: Roth conversion ladders, 72(t)/SEPP, and the Rule of 55.** All
three are real routes to tax-deferred money before 59½ without the penalty, and none is
represented (§13.3). The engine therefore treats tax-deferred balances as bridge-ineligible
even where a real household could reach them, which makes `bridgeGapDetected` deliberately
**conservative**: it can report a gap that a conversion ladder, a SEPP schedule, or a
well-timed separation would in fact close. The UI must say so wherever the flag appears,
rather than presenting the bridge as impassable.

### 8.4 Decumulation

Post-retirement the loop does not change (§6). What changes is that earned income has
stopped, so `netSurplus` turns negative and the gap is sourced through `withdrawalOrder`.
Each claimed person's `adjustedMonthlyBenefit × 12` joins income at their `claimingAge`
(§3.11, taxed per §4.3.1), and healthcare switches from ACA to Medicare at 65. Survival to
`projectionHorizonAge` is the real test; the FIRE-number crossing is the headline.

#### 8.4.1 Withdrawal sources

`withdrawalOrder` is `Assumptions.withdrawalOrder` (§3.9): an ordered list of
`WithdrawalSource` values rather than account IDs, distinguishing withdrawals by tax
character.

- `cash`: `cashSavings`/`cashChecking` balances; already-taxed dollars, so non-MAGI, no tax,
  no penalty. Drawn only **down to the cash-buffer target** (§4.5) while any other source
  remains; the buffer is breached only when everything else is exhausted
- `rothIraBasis`: `rothContributionBasis`, **from `rothIra` accounts only**; non-MAGI, tax-
  and penalty-free at any age
- `taxable`: a taxable-brokerage withdrawal, which comes out **pro rata as basis and gain**
  in the account's own ratio (§6.3). Only the gain portion is MAGI-counting and taxed
- `traditional`: `traditional401k`/`traditionalIra`/`traditionalTsp`/etc.; MAGI-counting, ordinary
  income. **Before 59½, also incurs `TaxYear.earlyWithdrawalPenaltyRate`** on the amount
  withdrawn (§8.3)
- `hsaQualifiedMedical`: `hsa` balance spent on that year's qualified medical costs;
  non-MAGI, tax- and penalty-free **at any age**, capped at the year's spending in the
  `health` meta-category **less any pre-65 ACA premium**, which is not a qualified expense.
  Medicare premiums after 65 are. That treatment makes an HSA the best-treated dollar in
  the model and puts it late in the default order
- `rothEarnings`: Roth balance beyond contribution basis, and the whole of a designated
  Roth balance that has not been rolled over; non-MAGI and tax-free once qualified (59½ *and* the
  account's five-year clock, from `Account.rothFirstContributionYear`). Before that it is
  ordinary income **and** incurs `TaxYear.earlyWithdrawalPenaltyRate`
- `hsaNonMedical`: `hsa` balance spent on anything else; ordinary income at any age, **plus
  a 20% penalty before 65** (`TaxYear.hsaNonMedicalPenaltyRate`). Last resort, and the
  reason it is last in the default order

Default order: `[cash, rothIraBasis, taxable, traditional, hsaQualifiedMedical, rothEarnings,
hsaNonMedical]`. This spends idle cash and non-MAGI sources first, then ordinary taxable
brokerage, before touching the accounts with the longest runway of tax-free growth.

**A taxable withdrawal yields basis and gain together, which is why it is one source rather
than two.** No brokerage withdrawal can take every dollar of basis out before any gain, and
§6.3's basis rule is explicitly pro rata. A $40,000 draw against an account that is 70% basis
produces $28,000 of untaxed return of capital and $12,000 of long-term gain. Specific-lot
identification could beat that, but the model holds no lots to identify (§13.2).

**`rothIraBasis` is IRA-only because the ordering rule it relies on is an IRA rule.** Roth
IRA distributions come out contributions first, tax- and penalty-free at any age, which
makes them the backbone of a bridge. A **designated Roth account**, meaning
`taxTreatment = roth` with `limitFamily = electiveDeferral`, has no such ordering: a non-qualified
distribution is pro rata basis and earnings under
§72(e)(8), with the earnings share taxed *and* penalized. Treating the two alike overstates
bridge-eligible assets for anyone whose Roth money sits in a workplace plan, which is most
high earners, on a test (§8.3) that gates the retirement date.

**A designated Roth account is assumed rolled to a Roth IRA at separation.** Households
actually do this, and without it workplace Roth basis would be permanently unreachable. At the
person's `retirementYear` the engine moves each such balance and its
`rothContributionBasis` into that person's `rothIra`, creating one if absent, takes the
**earlier** of the two accounts' `rothFirstContributionYear` as the receiving account's
five-year clock, and raises **`rothRolloverAssumed`**. Until that year, the balance is
reachable only as `rothEarnings`.

#### 8.4.2 Required minimum distributions

RMDs set a **floor on withdrawals**, standing outside `withdrawalOrder` entirely. The engine takes
them at the top of the year (§6), where they land as ordinary income and cash before the
pipeline runs. They apply to anyone past their RMD age, working or not.

```
for each Person with age(year) ≥ TaxYear.rmdAgeByBirthYear[birthDate.year]:
    for each Account owned by that Person where taxTreatment = taxDeferred:
        rmd = openingBalance / TaxYear.rmdDivisorTable[age(year)]

each rmd feeds rmdIncome, summed per TaxUnit in §4.3.1 and over taxUnits in §4.4
```

Four details the formula depends on:

- **Which accounts.** `taxDeferred` only: `traditional401k`, `traditional403b`, `traditionalIra`,
  `traditionalTsp`,
  `sepIra`, `simpleIra`. Roth IRAs have never had RMDs, designated Roth accounts no longer do, and
  HSAs
  never did. Applying RMDs to Roth balances is a common modeling error that understates
  their value precisely where it matters most.
- **Whose age.** The account **owner's**, using the IRS Uniform Lifetime Table, per account
  and summed. A sole-beneficiary spouse more than ten years younger uses the Joint Life
  table instead; that case is not modeled and slightly overstates the required amount.
- **Which balance.** The **opening** balance for the projected year, the real analogue of
  the prior December 31 figure, never the post-growth closing balance.
- **Where the excess goes.** An RMD larger than the year's spending need turns that year
  positive, and the waterfall reinvests what is left like any other surplus. That is the
  single loop earning its keep, since no separate rule is needed to stop the money vanishing.

#### 8.4.3 Health-cost transitions and IRMAA

Healthcare is the dominant expense lever in early retirement, and it changes character twice.

**Before 65**, coverage is ACA and its net cost is `acaBenchmarkPremium` less the premium tax
credit computed in §4.3.5, which depends on MAGI relative to the federal poverty level. This is
what `Assumptions.acaMagiCeilingPercentOfFpl` protects.

**At 65**, Medicare replaces it, and MAGI stops being free. The swap takes the whole year a
person turns 65 rather than splitting on their birth month, which understates that one year,
since Medicare runs cheaper than an unsubsidised pre-65 premium. Unlike 59½ (§3.1) this rounds
away from caution, costing one year on a figure that gates nothing.

Medicare Part B and Part D
premiums carry an income-related surcharge (**IRMAA**) assessed per person, in steps rather
than a phase-in, so one dollar over a threshold costs the entire step, and based on the
`TaxUnit`'s MAGI from **two years prior**:

```
for each Person with age(year) ≥ 65:
    lookbackMagi = federalAgi of that Person's TaxUnit in (year − 2), or in
                   currentYear where that falls before the projection begins
    tier         = highest TaxYear.irmaaBrackets[status] tier whose magiThreshold ≤ lookbackMagi
    medicareCost = 12 × (tier.partBPremium + tier.partDSurcharge)
```

`medicareCost` applies in **any** year the person is 65 or older, working or not, since it
turns only on age and the two-year MAGI lookback. It reaches expenses through §4.4's
`healthInsurance` term, so a Barista FIRE household still earning past 65 pays it too, and it
is booked to the `health` meta-category. Medicare premiums are qualified HSA expenses after
65, so leaving them out of that category would cap `hsaQualifiedMedical` below the
household's real medical spending and strand the balance. The engine retains two years of
`federalAgi` history per `TaxUnit` to support the lookback (§6).

**The MAGI ceiling does not stop applying at 65; it changes what it is aiming at.** Pre-65
the ceiling is `acaMagiCeilingPercentOfFpl` of the poverty line, protecting the premium tax
credit. From age 63 onward the binding constraint becomes the next IRMAA threshold, because
of the two-year lookback: income realized at 63 sets premiums at 65. The engine takes the
**lower** of the two ceilings in the overlapping years, so a household does not clear the ACA
cliff only to walk into the IRMAA one.

#### 8.4.4 ACA subsidy-aware ordering (pre-65)

`cash`, `rothIraBasis`, `hsaQualifiedMedical`, and the basis portion of a `taxable` draw do
not count toward MAGI; `traditional`, the gain portion of a `taxable` draw, `rothEarnings`
(unqualified) and `hsaNonMedical` do. Rather than solving jointly for the withdrawal mix that
maximizes lifetime after-tax-and-premium spending, a real optimization problem (§13.3), the
default order above becomes a **heuristic MAGI ceiling**.

**The ceiling binds only the MAGI-counting sources.** Those draws are limited to whatever
keeps MAGI at or below the active ceiling. `taxable` is bound *partially*: since only its
gain fraction counts, a ceiling with $10,000 of headroom against an account that is 30% gain
permits a draw of about $33,000. That fraction is the account's own basis ratio, so it falls
out of §6's maintenance without needing an assumption. The non-MAGI sources are drawn freely,
and the engine spends them first precisely so that MAGI-counting draws stay small. Only when
those balances are exhausted and the year's spending still is not covered does the engine
breach the ceiling, raise `magiCeilingBreached`, and accept the subsidy or premium loss
rather than under-funding the year. An RMD can breach it involuntarily, which is the point of
the flag.

This is the same rule of thumb FIRE planners apply by hand, capturing the bulk of the
available subsidy without engine complexity approaching a linear or dynamic program.

## 9. FIRE variants

Each of these falls out of the same engine, with no variant-specific entities.

### 9.1 Lean / Fat FIRE

*Early retirement on a deliberately small budget, or on a large one.*

The same plan at a different standard of living, and it needs no new field.
`ExpenseItem.phase` and `postRetirementAmount` (§3.7) already carry spending line by line
across the retirement boundary. Fat FIRE is a `preRetirementOnly` car, a
`postRetirementOnly` apartment, and a travel line whose `postRetirementAmount` is five times
its working figure. Lean is the same instrument the other way.

Keeping lean and fat side by side means two cloned `Household`s (§3.10), compared through
§10.2.

### 9.2 Barista FIRE

*Retiring early into part-time work, often kept for its health coverage, with savings already
funding the rest.*

An `IncomeStream` starting at that Person's own retirement, with an explicit `endYear`, since
the earned kinds otherwise default to ending the year before it (§3.3). The single loop (§6)
counts the wages as income and draws only the remaining gap, so nothing else is needed. Where
the job carries health insurance, extending that person's `employerHealthCoverageEndYear`
(§3.1) and adding the premium as a `PayrollDeduction` (§3.4.5) stops the engine charging them
an ACA benchmark premium and counting them toward the credit (§4.3.5). A 401(k) at that job needs
both
ends of its
`Contribution` window set (§3.4.1), a null `startYear` otherwise funding it from today against
pay that has not started.

A Barista FIRE scenario that also claims Social Security before FRA is the one place the
deferred retirement earnings test (§13.3) bites: the engine pays the full benefit where the
real program would withhold part of it against those earnings, and raises
**`earningsTestNotModeled`** for that year (§3.11).

### 9.3 Coast FIRE

*Saving only until the balance will reach the target on its own, then working on to cover
current costs while it compounds untouched.*

Coast FIRE sits before the retirement year and Barista after it. A coaster still covers
their whole cost of living from work; a barista's savings are already paying part of it.

Set `Contribution.endYear` on every account, **and omit the saving steps from that
scenario's `contributionWaterfall`** (§4.4.4), leaving `highInterestDebt`,
`cashBufferToTarget`, and `taxableBrokerage`. Both halves are needed. `Contribution` is only
the committed flow, so stopping it hands the same money to the waterfall, which pours it
back into the same accounts through steps 1, 2, 5, 6, and 7. Those steps gate on earned
income, which retires a household out of them but not a coasting one, still working by
definition.

The coast number is the balance today that
reaches the FIRE number with no further contributions, by the year each person reaches their
`plannedRetirementAge` where one is set and by the household's solved `retirementYear` (§8.2)
otherwise, and the coast number is itself `notReachable` where that is, there being no target
year to reach a FIRE number by. The target year is stated rather than assumed, since "traditional
retirement age"
means different things to a 62-year-old and a 67-year-old.

Reported as a **date**, interpolated within the crossing year. `coastingBalance(t)` is
`afterTaxLiquidNetWorth` at `t` in a projection where every `Contribution` and the waterfall
itself have both stopped, so balances grow only by their allocation's return. It is the
after-tax measure because that is the side of §8.2 leg 1 the FIRE number is compared against
(§8.1), and comparing a pre-tax balance to it would report a coast date years early. The
waterfall stops there for the same reason the plan above omits its saving steps, since a
balance still climbing on new money is not a coasting one. The
engine finds the first projected year `Y` reaching the target, then interpolates across it:

```
coastDate     = `alreadyCoasting`                 if coastingBalance(currentYear) ≥ target
              = January of Y + monthOffset months  otherwise

monthFraction = (target − coastingBalance(start of Y))
                / (coastingBalance(end of Y) − coastingBalance(start of Y))
monthOffset   = min(11, floor(monthFraction × 12))
```

The floor-and-clamp keeps the result inside year `Y`, since rounding a fraction near 1.0 up
to 12 would report January of `Y+1`, a year the engine never found a crossing in.

**A household already past its coast number gets `alreadyCoasting`**, the way one
that never reaches the FIRE number gets `notReachable` (§8.2). The crossing is behind them and
the engine never projects backward, so `monthFraction` would go negative and invent a date.

This is a **presentation-layer interpolation over an annual engine** (§1.2), claiming no
monthly fidelity, since it assumes the year's growth accrues smoothly. That assumption is
safe here because the underlying quantity is a smooth compounding curve rather than a lumpy
cash flow, which is why this is the one place the model reports sub-annual precision. It
makes "you can stop contributing in March 2031" legible where "2031" is not.

### 9.4 Traditional retirement

*Stopping at the conventional age, with no early years to bridge.*

`plannedRetirementAge` set to a traditional age, and nothing else. §6.1 takes that person
out of the retirement-year solve entirely, the bridge period (§8.3) is empty, and no
withdrawal is early enough to be penalised. It is the cheapest case the engine runs.

What changes is the question being asked. Someone retiring at 67 is not choosing a date, so
`fireNumber` answers something they never asked: it prices a standard of living they have
already committed to a year for. They want the inverse, and §5 computes it.
`sustainableLevelSpending` is what their projected balance will actually support, and
`spendingHeadroom` is the annual distance between that and what they currently plan to
spend. Both read at their retirement year, both in today's dollars (§1.1).

The two measures answer for any household, and they are the headline only here. A household
solving for a date reads `fireNumber` against `afterTaxLiquidNetWorth`; a household with the
date already fixed reads the same comparison from the other end.

---

## 10. Progress tracking and snapshots

The engine (§6) always recomputes fresh from current household state. There is no sense in
which "today's projection" is a delta layered onto "January's projection." What makes the app
forward-looking across edits is a **history of `ProjectionSnapshot`s (§3.13)** that the live
projection can be compared against.

### 10.1 When a snapshot is written

**Automatic:** on every saved edit to a scenario's household state, its `Assumptions`, or the
`AssetClass` rates it projects under (§3.9), all three being inputs the output moves with,
at most one auto-snapshot per `scenarioId` per calendar day: each qualifying edit writes a
new snapshot and deletes the day's superseded `auto` one, so a sitting collapses to the state
the user settled on rather than to the first thing they typed. A throttle that simply dropped
later edits would keep the wrong end of the day. Before writing, the engine
compares `inputDigest` against the most recent snapshot for that scenario and skips the write
entirely if nothing actually changed.

**Manual:** the user can pin a checkpoint at any time, with an optional `label`. This is not
throttled; a deliberate "save this as a checkpoint" always writes.

Because a snapshot stores only the output summary (§3.13), even years of daily
auto-snapshots stay cheap under local-only storage (§1.4). No retention policy is needed for
v1.

### 10.2 Comparing snapshots

A **comparison between any two `ProjectionSnapshot`s** is computed on demand and is not
itself a stored entity. It surfaces: Δ retirement year, Δ FIRE number and Δ sustainable
level spending, all three per band, Δ net worth (all four measures), Δ savings rate, and the
elapsed time between `asOfDate`s. A household with a fixed retirement date reads the third
where one solving for a date reads the first (§9.4).
Where either side of a per-band pair is `notReachable` the comparison names the transition
rather than a difference, there being no arithmetic between a year and its absence. Within
one `scenarioId` this powers a "your retirement date has moved from 2039 to 2038 since
March" view, and a net-worth-over-time and retirement-date-over-time trend chart across
that scenario's snapshots.

**The two sides need not share a scenario or a household**, and the comparison says what
differs between them: each side's `Scenario.assumptions`, its `Household`, its `taxYearId`,
or more than one at once.
Comparing two cloned `Household`s is how a user sees one job against another (§3.10), and
that comparison has no time axis, so the elapsed-time figure is omitted where the two
`asOfDate`s are the same. A comparison whose sides differ in more than one of the three
is shown and labeled, since attributing the delta to any single cause would be wrong.

For `taxYearId` in particular, part of the delta is then a change in the bundled rules
rather than a change in the plan, and attributing it to the household would be wrong.

**This tells the user *that* their trajectory moved.** Decomposing a change into
its drivers would require re-running the engine with mixed old and new inputs to isolate each
factor, which is real additional work, so it is deferred (§13.1) in the same way ACA withdrawal
optimization (§8.4.4) and the retirement tax rates (§8.2) each take a cheap, honest
approximation in place of an accurate, expensive one.

---

## 11. Data, privacy, and portability

- All persistence is local. No telemetry, no analytics, no crash reporting containing user
  data.
- **Export** produces a single versioned JSON file containing every household (persons, tax
  units, income streams, employers, accounts, payroll deductions, assets, liabilities, expense
  categories and the items under them, and one-time events) together with the scenarios and
  snapshots
  that belong to it, and the `AssetClass` set, whose rates the user edits and no bundle can
  restore. Categories are named separately because `ExpenseItem.categoryId` is an item's only
  path to its `Household` (invariant 1). Because a scenario carries `Assumptions` and never overlays
  household data (§3.10), each household is
  written once however many scenarios point at it. An explicit schema version drives
  migration.
- **Import** validates against the schema version and migrates forward.
- Backup prompting is a product requirement, since local-only storage means an unbacked-up
  device loss is unrecoverable.
- Bundled `TaxYear` data is the only thing that ships in; nothing ships out.

---

## 12. Invariants

**Structural**

1. Every `ExpenseItem` belongs to exactly one `ExpenseCategory`, which is how it reaches a
   `Household`.
2. Every `IncomeStream`, `Account`, and `PayrollDeduction` belongs to exactly one `Person`.
3. Every `Person` belongs to exactly one `TaxUnit`, named by `Person.taxUnitId`, which is
   the only membership link and the one both directions are counted from. A
   `marriedFilingJointly` unit has exactly two `Person`s; **every other status,
   `marriedFilingSeparately` included, has exactly one**. Filing separately means two
   returns, so a couple doing it is two `TaxUnit`s of one person each, inside one
   `Household`.
4. Every `TaxUnit`, `Asset`, `Liability`, `ExpenseCategory`, `OneTimeEvent`, and `Scenario`
   names an existing `Household` in `householdId`, and nothing else carries one. Where an
   attributed `personId` supplies a second path to a `Household`, invariant 25 holds
   the two together.
5. `Asset.securedByLiabilityId` and `Liability.securedAssetId` must agree.
6. Every `ProjectionSnapshot.scenarioId` must reference an existing `Scenario`; a deleted
   scenario's snapshots are deleted with it, and a deleted `Household` takes its scenarios,
   and so their snapshots, with it. The cascade is specified at every level or it dangles at
   the one it skips.
7. `Account.allocationWeights` sums to 1.0 when `allocationMode = weighted` (§3.4).
8. `Contribution.contributionBaseStreamIds` is non-empty when `mode = percentOfGross`, and
   every id references an `IncomeStream` belonging to the same `Person` as the account (§3.4.1).

**Representation**

9. Rates are stored as decimals (0.05, not 5). Percent is a display concern only.
10. Money is stored in integer cents. No floats. `Contribution.value` is the one field
    carrying either representation, a decimal rate under `percentOfGross` and cents under
    `fixedAmount`, its `mode` selecting which (§3.4.1).
11. `Person.birthDate` is a full date. Every age used by the engine is the age *attained
    during* the projected year (§3.1), except 59½, which uses the explicit rule in §3.1.
12. Every `Money` field is non-negative; `OneTimeEvent.amount` is the sole exception and
    declares itself signed (§3.8). A negative `Contribution.value` would otherwise act as a
    withdrawal skipping `withdrawalOrder` and its penalties. Rates carry no sign constraint,
    several being negative by design (§3.5, §3.7, §3.9).

**Accounting**

13. `Account.costBasis ≤ Account.balance` for taxable accounts at entry (warn, do not block;
    losses are real). The engine maintains basis thereafter per §6.3, and a projected basis
    above balance is a genuine unrealized loss.
14. `rothContributionBasis ≤ balance` for Roth accounts, at entry and after every projected
    year.
15. `monthlyEscrowAmount ≤ monthlyPayment` and `monthlyPmiAmount ≤ monthlyEscrowAmount` where
    each is set, since escrow is a portion of the payment and PMI a portion of escrow (§3.6).
    `escrowContinuesAfterPayoff` is in [0, 1].
16. **No expense is counted twice.** Five mechanisms already carry spending into
    `netSurplus`, and an `ExpenseItem` must not duplicate any of them:

- a `Liability`'s payment reaches cash flow through §4.4's `debtService` term, which also
  carries the escrow that outlives a payoff, so no `ExpenseItem` may represent a loan
  payment or any escrow, before or after;
- a `PayrollDeduction` is money that never reaches the paycheck, so no `ExpenseItem` may
  represent a premium or FSA-funded cost already deducted;
- an `Account` with `targetBalanceMonths` is funded by the waterfall, not by an expense
  line;
- health insurance is an engine term (§4.4's `healthInsurance`), so no `ExpenseItem` may
  represent a health premium. A person still on employer coverage is expressed with
  `employerHealthCoverageEndYear` and a `PayrollDeduction`;
- an `OneTimeEvent` outflow is spending already, drawn from its `accountId` and falling
  to `oneTimeNet` where the account cannot cover it (§3.8), so no `ExpenseItem` may
  restate the truck or the repair it paid for.

  This is a warn-and-flag check (`possibleDoubleCount`), not a block: the engine cannot
  prove two similarly-named lines are the same obligation.

17. An `OneTimeEvent` with a negative `amount` must name an `accountId` (§3.8). Inflows may
    leave it null.
18. An `Asset` with `plannedSaleYear` set must name a `saleProceedsAccountId` (§3.5).
19. `ProjectionSnapshot`s are immutable once written and are never recomputed or edited in
    place; a plan change produces a new snapshot. A same-day snapshot with `trigger =
    auto` that a later edit supersedes is **deleted** rather than edited (§10.1), which is how a
    sitting
    collapses to one row while every row stays immutable. A `manual` snapshot is never
    deleted this way, that being the point of pinning one.

**Limits**

20. Per-person annual contributions do not exceed the limits for their account's
    `limitFamily` (§3.4.2): **cap in projection and raise `contributionLimitExceeded`**, do not
    block entry, since the user may be recording an actual over-contribution.
21. A `Person` whose active `hsaCoverage` tier is `none`, or who is 65 or older, may not make
    a non-zero `hsa` `Contribution` in that year. A `family` tier shares one base limit across
    the `TaxUnit`; the 55-and-over catch-up is per person and is never shared (§3.1, §3.4.2).
22. `Asset.accumulatedDepreciation ≤ Asset.costBasis × (1 − landFraction)`. Outside
    `investmentProperty`, `accumulatedDepreciation` is zero and `landFraction` is unread
    (§3.5).
23. A `Dependent`'s `supportEndYear ≥ birthDate.year`. A `TaxUnit` filing `headOfHousehold`
    in a year with no active dependent is computed as `single` for that year and flagged, not
    blocked (§3.2).
24. A waterfall step that funds a retirement account requires that person to have earned
    income that year (§4.4.4), as does a committed `Contribution` to one. A `percentOfGross`
    contribution self-gates, its base being zero; a `fixedAmount` one does not, which is
    what this catches.
25. An `Asset`, `Liability`, or `OneTimeEvent` must name a `personId` once its `Household`
    holds more than one `TaxUnit`, and that `Person` must belong to that `Household`.
    §4.3's sums are per `TaxUnit`, so an unattributed one would reach both returns. Where
    a single `TaxUnit` exists, null resolves to it and nothing need be entered.
26. Every `Account`, `ExpenseCategory`, or `Employer` named by another entity belongs to
    the same `Household` as the entity naming it.
    Invariants 16 and 17 require the account and category references to exist; this
    keeps all three inside the household, so money cannot land, and a match cannot be sized,
    where the projection stops seeing it.
27. `SocialSecurityBenefit.claimingAge` is in [62, 70]. §3.11's `monthsLate` term is
    unbounded on its own, so a later age would award delayed-retirement credits that
    statute stops accruing at 70.
28. `Assumptions.safeWithdrawalRate` is greater than 0, and `retirementDurationYears` (§5)
    is at least 1. §8.1 divides by `r` twice and by an annuity that is 0 at `N = 0`, which a
    `plannedRetirementAge` equal to `projectionHorizonAge` reaches.
29. An `Account` whose `taxTreatment` is `roth` or `taxDeferred` has a `limitFamily` other
    than `none`. Both are stored, so a custom account could otherwise pair Roth treatment
    with an uncapped family and contribute without bound (§3.4.2).
30. `Assumptions.contributionWaterfall` contains `taxableBrokerage`. Every other step may be
    omitted, and Coast FIRE omits five of them (§9.3), but a waterfall with no terminal step
    leaves a positive `netSurplus` unallocated with no account to hold it (§4.4.4).

## 13. Deferred

Each item below is explained where the mechanism it touches is defined; the section
reference points there. An entry that moves a projected number says which way, so the
optimistic ones read as a group, and those whose condition the engine can detect carry a flag
(§6) rather than prose.

### 13.1 Modeling scope

- Monte Carlo simulation, historical-sequence backtesting, and sequence-of-returns risk
  generally (§1.5)
- Non-US jurisdictions, and US territories (§7.6)
- Multi-state and part-year residency
- Estate planning and inheritance tax
- Capital improvements to an `Asset` after entry, which would raise `costBasis` and
  **lower** the gain on sale (§3.5)
- Borrowing that funds no acquisition, such as a cash-out refinance or a personal loan taken
  as income. A new `Liability` raises debt service and no balance (§3.6)
- Long-term care cost modeling, which **understates** retirement expenses and is the largest
  unmodelled tail in a multi-decade retirement. No condition predicts it, so it carries no flag
- Mortality, and every event that depends on it: a spouse's death, the resulting
  filing-status change, and the Social Security survivor benefit. `projectionHorizonAge` is a
  fixed horizon, not a death event, so none of this can be expressed today.
- Per-scenario `AssetClass` return rates, so two scenarios can differ on what markets do
  rather than only on what the household does (§3.10)
- Scenario overrides: sharing one `Household` across scenarios through a sparse per-entity
  override layer, with the merge-precedence rules and comparison semantics it would require
  (§3.10)
- Attributing a change between two `ProjectionSnapshot`s to its drivers (§10.2)
- Reverting or replaying a scenario against a prior snapshot's full input state

### 13.2 Tax

- Itemized deduction **derivation** from mortgage interest, SALT, charitable giving, and
  medical expenses (§3.2)
- AMT, which **understates** tax for the few households post-2017 exemptions still reach
- Federal credits beyond the Child Tax Credit: Saver's Credit, Child and Dependent Care
  Credit, education credits, EITC (§3.12)
- Tax-exempt interest as an income kind, which slightly understates taxable Social Security
  for anyone holding munis (§4.3.1)
- QBI limits above the threshold: the W-2-wage and unadjusted-basis limitations and the SSTB
  phase-out. The engine applies the unlimited 20% and raises `qbiLimitNotModeled` (§4.3.2)
- Capital losses, including the carryforward and the $3,000 ordinary offset (§6.3)
- The rate cap on unrecaptured §1250 gain, statutorily the lesser of 25% and the marginal
  rate. The flat 25% **overstates** tax for a household in a lower bracket at sale (§3.5)
- Specific-lot identification on taxable withdrawals (§8.4.1)
- Deferring Medicare past 65 while covered by an employer HDHP, and the six-month retroactive
  Part A start (§3.4.2)
- Filing-status transitions other than `headOfHousehold` falling back to `single` (§3.2)
- Equity compensation beyond simple RSU vesting: ISOs, ESPP, 83(b)
- The additional standard deduction for blindness. The age-65 addition **is** modeled (§4.3.2)

### 13.3 Retirement mechanics

- **Roth conversion ladders.** The most common bridge strategy in practice (§8.3), and not a
  flag that can be flipped on. It needs a `RothConversion` entity (year, amount, source
  account, destination account); the conversion recognized as ordinary income in its year; a
  **separate five-year clock per conversion**, distinct from the account's own; and the direct
  conflict with §8.4.4's ACA MAGI ceiling, since a conversion's whole purpose is to fill low
  brackets with MAGI-counting income that the ceiling exists to suppress. Modeling it without
  that conflict would make the ladder look free. The **backdoor Roth** and the §408(d)(2)
  pro-rata rule are blocked by the same missing entity, which is why waterfall step
  `iraToLimit` stops at the Roth IRA income limit and raises `rothIraIncomeLimitReached`.
- **72(t)/SEPP schedules and the Rule of 55** as penalty-free routes across the bridge period
  (§8.3). *72(t)/SEPP* needs the three IRS calculation methods (required minimum distribution,
  fixed amortization, fixed annuitization), each producing a different annual figure; the
  interest-rate and life-expectancy inputs those methods consume; a per-account election
  entity, since a schedule is sized against one account's balance and households routinely
  split an IRA to size it; the lock-in that fixes the amount once elected; and the
  modification rule, which retroactively applies the penalty to *every* distribution taken
  under the schedule, with interest, if it is broken before the longer of five years or 59½.
  *Rule of 55* has half of what it needs in `Account.employerId` (§3.4) and lacks the other
  half, a separation date per employer: the exemption reaches only the plan of the employer
  separated from in or after the year the person turns 55, so knowing *which* employer is not
  enough without knowing *when* the person left.
- Social Security spousal benefits, with the documented workaround in §3.11
- The Social Security retirement earnings test, which makes the engine overstate benefit
  income in pre-FRA working years (§3.11, §9.2)
- Vesting-aware balances. `EmployerMatch.vestingSchedule` is surfaced as
  `unvestedMatchAtRisk` and reduces no balance (§3.4.4)
- A true joint optimizer for ACA subsidy vs. lifetime tax during decumulation, replacing the
  MAGI-ceiling heuristic (§8.4.4)
