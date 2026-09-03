# Slow Burn Domain Model

**Status:** Draft · 2026-09-03

Slow Burn is a FIRE calculator that is free, private (nothing leaves the device), and
fits your life. It models a household's income, taxes, savings, assets, liabilities,
and expenses, then projects them forward to answer one question: **when can you stop
working?**

This document defines the domain: the entities, their fields, the derived quantities,
the order in which they are computed, and the invariants that must hold. It is the
reference the calculation engine and the UI are both written against.

---

## 1. Foundational modeling decisions

### 1.1 All money is in today's dollars (real, not nominal)

Every stored amount, every rate, and every projected figure is **real**, expressed in
present-day purchasing power.

- Asset appreciation rates are **real returns** (a user entering 5% for stocks means
  5% above inflation).
- Income growth is a **real** raise rate (0% means "keeps pace with inflation").
- Expenses do not inflate year over year by default, because they are already in
  today's dollars. A per-expense **relative** inflation rate captures categories that
  outpace general inflation (healthcare at +2.5% real, for example).
- Tax brackets are treated as inflation-indexed, so they are held constant in real
  terms across projected years. Thresholds that are **not** indexed in statute (the
  Additional Medicare Tax, NIIT, and Social Security benefit taxability thresholds)
  are explicitly deflated each projected year. See §7.4.

**Why this matters:** Working in real dollars throughout makes the safe-withdrawal-rate
input mean what users think it means, and makes "you retire in 14 years" legible without
mentally deflating a number. A naive nominal formula can look correct on paper while
implying a near-zero real withdrawal rate. Real dollars throughout avoids that trap.

A **nominal display toggle** may inflate outputs for presentation, but the engine is
real-only. Inflation assumption (`Assumptions.generalInflationRate`) is stored solely
to support that display toggle and to convert user-entered nominal rates on input.

### 1.2 Annual granularity

The projection engine steps in **whole years**. Sub-annual behavior (paycheck timing,
monthly cash buffer accumulation) is modeled as an annual aggregate.

Expenses and contributions may be *entered* at any frequency and are normalized to
annual on save. The cash buffer is the one place where the annual approximation is
visibly wrong; it is handled with a fill-to-target rule (§4.4) rather than by moving
the whole engine to monthly steps.

Every projection run has an `asOfDate` (the date it's run, not just a year), and its
first year is prorated to the remaining fraction of that calendar year rather than
treated as a full year (see §6). This is what lets a projection run in August reflect
August correctly instead of double-counting January–August or padding out months
that already happened.

### 1.3 United States only

FICA, Medicare, state income tax, 401(k)/HSA/IRA account kinds, ACA subsidies, and
Social Security are all US constructs and are modeled directly rather than
generalized. Internationalization is out of scope and should not be designed around.

### 1.4 Local-only storage

"We harvest nothing" is a domain constraint, not just a privacy posture. It implies:

- **Tax tables ship with the app.** There is no server to push a new tax year from.
  A new `TaxYear` ruleset requires an app update. The engine must therefore degrade
  gracefully when the current calendar year is newer than the newest bundled
  `TaxYear` (§7.5).
- **No cross-device sync**, and no account recovery.
- **Export / import is a first-class feature**, not a nice-to-have. Device loss
  otherwise means total data loss. See §11.

### 1.5 Deterministic projection with three return bands

Projections are deterministic, but always run **three bands** (`pessimistic`, `expected`,
`optimistic`), each using the corresponding rate stored directly on every `AssetClass`
(§3.9). Results are always presented as a range.

A single point estimate is the classic overconfidence failure of FIRE calculators: it
presents one long-run average as if it were a forecast, hiding how sensitive the plan is
to which long-run average actually shows up. Three bands surface that sensitivity as a
range instead of a false-precision point.

**This is a parameter-uncertainty range, not a sequence-of-returns model.** Each band
applies one constant rate to every year, so it says nothing about *ordering* — a market
crash the year after retiring is far more damaging than the same crash a decade in, and
a constant-rate band can't distinguish the two. Monte Carlo and historical-sequence
backtesting, which do model ordering, are deferred (§13); the `Scenario` and result types
are shaped so that adding a distribution of outcomes later does not change their
signatures.

---

## 2. Entity overview

```
Household
├── Person (1..n)                     — owns income, accounts, ages, benefits
├── TaxUnit (1..n)                    — a filing entity; groups Persons
│   └── filingStatus, state, locality
├── IncomeStream (0..n)               — belongs to a Person
├── Account (0..n)                    — balance + contribution; belongs to a Person
├── Asset (0..n)                      — non-account holdings (home, car, cash)
├── Liability (0..n)                  — debts, optionally secured by an Asset
├── ExpenseCategory (0..n)            — groups ExpenseItems
├── ExpenseItem (0..n)                — belongs to an ExpenseCategory
├── OneTimeEvent (0..n)               — windfalls and lumpy costs
└── Scenario (1..n)                   — a named set of Assumptions to project under
    └── ProjectionSnapshot (0..n)     — frozen output history for that scenario (§3.13)

AssetClass (reference data: return rates by class — §3.9)
TaxYear (reference data, versioned, bundled with the app)
```

`Account` unifies what could otherwise be two separate ideas: a savings *flow* (a
contribution rate) and an *stock* of value (a balance). A 401(k) is one entity with a
balance *and* a contribution rate, not two objects that need to stay in sync.

---

## 3. Entities

### 3.1 Person

The unit that FICA caps, contribution limits, and age-gated account access apply to.

| Field                  | Type                   | Notes                                                                                                     |
|------------------------|------------------------|-----------------------------------------------------------------------------------------------------------|
| `id`                   | ID                     |                                                                                                           |
| `displayName`          | string                 |                                                                                                           |
| `birthYear`            | int                    | **Required.** Drives 59½ access, catch-up eligibility, Medicare at 65, Social Security claiming, RMD age. |
| `taxUnitId`            | ID                     | Which filing entity this person belongs to.                                                               |
| `plannedRetirementAge` | int?                   | Optional override; otherwise solved for.                                                                  |
| `socialSecurity`       | SocialSecurityBenefit? | See §3.11.                                                                                                |

**Why per-person matters:** the Social Security wage base cap, 401(k) deferral limits,
IRA limits, HSA limits, and catch-up contributions are all assessed per individual.
Computing them on a household total gives materially wrong answers for exactly the
dual-income high-earner households this app targets.

### 3.2 Household and TaxUnit

Resources are shared among people who file taxes differently: spouses file jointly and
share brackets, deductions, and thresholds; friends pooling expenses do not. Modeling
them identically produces wrong tax for both, so the two concepts are split.

**Household**: the pooled economic unit. Aggregates net worth, expenses, and
projections. Has no tax meaning.

| Field            | Type | Notes                                                                                           |
|------------------|------|-------------------------------------------------------------------------------------------------|
| `id`             | ID   |                                                                                                 |
| `personIds`      | ID[] |                                                                                                 |
| `expenseSharing` | enum | `pooled` \| `proportional` \| `explicit`: how shared expenses are attributed. Default `pooled`. |

**TaxUnit**: one tax return.

| Field            | Type    | Notes                                                                                                       |
|------------------|---------|-------------------------------------------------------------------------------------------------------------|
| `id`             | ID      |                                                                                                             |
| `filingStatus`   | enum    | `single`, `marriedFilingJointly`, `marriedFilingSeparately`, `headOfHousehold`, `qualifyingSurvivingSpouse` |
| `stateCode`      | string? | Null for no-income-tax states, or resident state code.                                                      |
| `localityCode`   | string? | NYC, Philadelphia, Ohio municipality, Maryland county, etc.                                                 |
| `personIds`      | ID[]    | One person for `single`; two for `marriedFilingJointly`.                                                    |
| `dependents`     | {birthYear: int}[] | One entry per dependent. Count (`.length`) drives HoH qualification; each `birthYear` drives Child Tax Credit qualification (§4.3 — under age 17 in the tax year) and its phase-out. |

`expenseSharing` and `filingStatus` are independent axes, not linked. A married
couple filing `marriedFilingSeparately` can still choose `pooled` household expense
sharing; unmarried partners can choose `proportional`. `filingStatus` lives on
`TaxUnit`; `expenseSharing` lives on `Household`; neither implies the other.

`proportional` splits each shared `ExpenseItem` by each `TaxUnit`'s share of total
household after-tax income for that year, recomputed annually as incomes change.
`explicit` requires a per-item split entered directly ("I pay the mortgage, you pay
groceries").

A household of two friends is one `Household` containing two `TaxUnit`s, each with one
`Person`. A married couple is one `Household` with one `TaxUnit` containing two
`Person`s. Taxes are always computed per `TaxUnit` and then summed to the household.

### 3.3 IncomeStream

| Field                   | Type   | Notes                                                                                                                          |
|-------------------------|--------|--------------------------------------------------------------------------------------------------------------------------------|
| `id`                    | ID     |                                                                                                                                |
| `personId`              | ID     | Owner: determines whose FICA cap applies.                                                                                      |
| `label`                 | string |                                                                                                                                |
| `kind`                  | enum   | `w2Wages`, `selfEmployment`, `bonus`, `rsuVesting`, `rentalNet`, `pension`, `other`                                            |
| `grossAnnualAmount`     | Money  |                                                                                                                                |
| `realGrowthRate`        | Rate   | **Per stream**, not global. Expresses "my salary grows 1% real, my spouse's is flat" instead of one household-wide raise rate. |
| `growthEndYear`         | int?   | When raises stop. Defaults to **this stream's own Person's** retirement (their `plannedRetirementAge`, or the solved year if unset) — per-person, not the household's overall `retirementYear`, so one spouse's raises can keep accruing after the other's stop. |
| `startYear` / `endYear` | int?   | Supports a contract ending, a career change, a spouse returning to work.                                                       |
| `isFicaSubject`         | bool   | Derived from `kind`, overridable.                                                                                              |
| `variability`           | enum   | `guaranteed` \| `variable`: bonuses and RSUs should be visibly flagged as not-guaranteed in projections.                       |

**`kind` drives payroll tax treatment:** `selfEmployment` pays both halves on 92.35% of
net earnings — 12.4% OASDI (sharing the wage-base cap with any W-2 wages the same person
has) plus 2.9% uncapped Medicare, with half of the total deductible above the line (§4.2
has the exact formula; it is *not* a flat 15.3% once the wage base binds). `rentalNet`
and `pension` are income-tax-only, no FICA.

### 3.4 Account

A single entity carrying both the balance (stock) and the contribution rate (flow) for
any savings or investment vehicle.

| Field                   | Type         | Notes                                                                                                                                                            |
|-------------------------|--------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                    | ID           |                                                                                                                                                                  |
| `personId`              | ID           | Owner. Contribution limits are per person.                                                                                                                       |
| `label`                 | string       |                                                                                                                                                                  |
| `kind`                  | enum         | `traditional401k`, `roth401k`, `traditionalIRA`, `rothIRA`, `hsa`, `fsa`, `tsp`, `sepIra`, `simpleIra`, `529`, `taxableBrokerage`, `cashSavings`, `cashChecking` |
| `taxTreatment`          | enum         | `taxDeferred` \| `roth` \| `taxable` \| `hsaTriple`: *derived from `kind`*, but stored so custom accounts are expressible.                                       |
| `balance`               | Money        | Current value. The **stock**.                                                                                                                                    |
| `costBasis`             | Money        | Required for `taxable`. Needed to compute capital gains tax on withdrawal or sale.                                                                               |
| `rothContributionBasis` | Money        | For `roth` accounts: the portion withdrawable penalty-free before 59½. Critical to the bridge period (§8.3).                                                     |
| `contribution`          | Contribution | The **flow**. See below.                                                                                                                                         |
| `allocationMode`        | enum         | `singleClass` \| `weighted`: user-facing switch between a simple single-`AssetClass` rate and a blended, weighted mix.                                          |
| `assetAllocationId`     | ID           | For `allocationMode = singleClass`: the one `AssetClass` determining growth rate.                                                                                |
| `allocationWeights`     | {assetClassId, weight}[] | For `allocationMode = weighted`: weights summing to 1.0, blended into a weighted-average real return each year.                                    |
| `isLiquid`              | bool         | Derived: true for all account kinds.                                                                                                                             |
| `targetBalanceMonths`   | number?      | Only meaningful for the household's designated cash-buffer account(s) (typically `cashSavings`). Expressed as months of `annualExpenses`, not a fixed Money amount, since expenses change year to year — the Money target is `targetBalanceMonths × annualExpenses / 12`, recomputed each projected year. Null for every other account. See §4.4 step 4 and §4.5. |

**Contribution** (embedded):

| Field                         | Type           | Notes                                                                                                                    |
|-------------------------------|----------------|--------------------------------------------------------------------------------------------------------------------------|
| `mode`                        | enum           | `percentOfGross` \| `fixedAmount`: people set 401(k) as a percent and IRAs as a dollar figure; both must be first-class. |
| `value`                       | number         | Percent or Money depending on `mode`.                                                                                    |
| `contributionBaseStreamIds`   | ID[]           | Which of the person's `IncomeStream`s the percentage applies to. Required when `mode = percentOfGross`; ignored otherwise. |
| `employerMatch`               | EmployerMatch? | See below.                                                                                                               |
| `reducesFederalTaxableIncome` | bool           |                                                                                                                          |
| `reducesStateTaxableIncome`   | bool           |                                                                                                                          |
| `reducesFicaWages`            | bool           |                                                                                                                          |
| `stopYear`                    | int?           | Enables Coast FIRE (§9.3).                                                                                               |

**Every formula in §4 that sums `Contribution`s (or their `value`) means the resolved
dollar amount for the year, not the raw stored `value`.** That is `resolvedAmount`:

```
base           = Σ grossAnnualAmount over IncomeStreams in contributionBaseStreamIds
uncapped       = value                    if mode = fixedAmount
               = value × base             if mode = percentOfGross

catchUp        = TaxYear.contributionLimits catch-up amount, if age ≥ its eligibility age
electiveCap    = TaxYear.contributionLimits.electiveDeferral    + catchUp
totalCap       = TaxYear.contributionLimits.annualAdditions415c + catchUp

resolvedAmount = min(uncapped, electiveCap, max(0, totalCap − employerMatchThisAccount))
```

**The base streams are named explicitly, never inferred.** A person can hold `w2Wages`,
`bonus`, and `rsuVesting` at once, and real plans differ on which count as eligible
compensation. Ten percent of a $180,000 salary and ten percent of that salary plus a
$40,000 bonus differ by $4,000 a year, compounding for decades — there is no defensible
default, so the streams are listed.

**Employer match does not reduce the elective deferral limit.** Two separate statutory
caps apply, and only one of them sees the match:

- The **elective deferral limit** (§402(g)) governs employee contributions alone. A
  match consumes none of it: someone earning $200,000 whose employer contributes
  $10,000 can still defer the full elective limit themselves.
- The **total annual additions limit** (§415(c)) governs employee and employer
  contributions together, and the match does count against it.

So the elective limit is normally what binds, and `totalCap − match` only bites for a
high earner whose match is large enough that the two together approach the 415(c)
ceiling. Catch-up contributions sit *outside* both caps rather than inside them, which
is why they are added to each above rather than netted out of either.

Both caps are assessed **per person across every account sharing them**, not per
account: someone who changed jobs mid-year and holds two `traditional401k`s gets one
elective deferral limit between them. Where the uncapped total across those accounts
exceeds a limit, each is reduced pro rata by its share, matching §4.4's rule for
splitting a partially funded waterfall step. This is where §12's invariant 6 ("warn and
cap in projection") is enforced.

**The three `reduces*` flags carry the actual tax treatment of each contribution
type.** 401(k), 403(b), and TSP deferrals reduce federal and (usually) state income
tax but **do not** reduce FICA or Medicare wages. Only Section 125 cafeteria-plan
items (HSA via payroll deduction, FSA, employee-paid insurance premiums) reduce FICA
wages. The same flags also capture state divergence: Pennsylvania taxes 401(k)
contributions at the state level even though the federal government does not.

Defaults by kind:

| Kind                                                    | Federal | State                           | FICA                |
|---------------------------------------------------------|---------|---------------------------------|---------------------|
| `traditional401k`, `tsp`, `traditionalIRA` (deductible) | reduces | reduces (except PA and similar) | **does not reduce** |
| `hsa` via payroll                                       | reduces | reduces (except CA, NJ)         | **reduces**         |
| `hsa` direct contribution                               | reduces | varies                          | does not reduce     |
| `fsa`                                                   | reduces | reduces                         | reduces             |
| `roth401k`, `rothIRA`                                   | no      | no                              | no                  |

**EmployerMatch** (embedded): free money flowing into assets that does not come out of
the employee's own income:

| Field                       | Type             | Notes                                                                                                   |
|-----------------------------|------------------|---------------------------------------------------------------------------------------------------------|
| `formula`                   | enum             | `percentOfContribution` \| `percentOfSalary` \| `tiered`                                                |
| `matchRate`                 | Rate             | For `percentOfContribution`/`percentOfSalary`. e.g. 0.50 for a 50% match.                               |
| `matchLimitPercentOfSalary` | Rate             | For `percentOfContribution`/`percentOfSalary`. e.g. 0.06 ("50% of the first 6%").                       |
| `tiers`                     | {upToPercentOfSalary: Rate, matchRate: Rate}[] | For `formula = tiered` only: ordered tiers, each applying `matchRate` to the slice of contribution between the previous tier's cutoff and this one's `upToPercentOfSalary`. e.g. `[{upToPercentOfSalary: 0.03, matchRate: 1.00}, {upToPercentOfSalary: 0.05, matchRate: 0.50}]` = "100% of the first 3%, 50% of the next 2%." |
| `vestingSchedule`           | VestingSchedule? | `immediate` \| `cliff(years)` \| `graded(schedule)`: affects what you can count on if you retire early. |

### 3.5 Asset

Holdings that are not accounts (`Account` covers savings and investment vehicles;
`Asset` covers everything else the household owns).

| Field                    | Type   | Notes                                                                                         |
|--------------------------|--------|-----------------------------------------------------------------------------------------------|
| `id`                     | ID     |                                                                                               |
| `householdId`            | ID     | Owner.                                                                                         |
| `label`                  | string |                                                                                               |
| `category`               | enum   | `primaryResidence`, `investmentProperty`, `vehicle`, `collectible`, `businessEquity`, `other` |
| `currentValue`           | Money  |                                                                                               |
| `costBasis`              | Money  |                                                                                               |
| `realAppreciationRate`   | Rate   | Per asset, defaulted from category, user-overridable. Vehicles default negative.              |
| `isLiquid`               | bool   | **Defaults `false` for every category.** `Asset` exists for holdings `Account` doesn't cover (§3.5 intro) — genuinely liquid things are already an `Account`, so an `Asset` is illiquid unless overridden (e.g. a collectible the user considers readily sellable). |
| `countsTowardFireNumber` | bool   | Default `= isLiquid`.                                                                         |
| `securedByLiabilityId`   | ID?    | Links a house to its mortgage.                                                                |
| `plannedSaleYear`        | int?   | Downsizing converts an illiquid asset to a liquid one.                                        |

**`isLiquid` keeps the retirement test honest.** A household with a $600k paid-off
house has real net worth but nothing there to spend. The FIRE test uses liquid net
worth only (§8.2), not total net worth.

### 3.6 Liability

Debts, tracked as first-class entities rather than folded into net worth or expenses.

| Field                            | Type       | Notes                                                                                 |
|----------------------------------|------------|---------------------------------------------------------------------------------------|
| `id`                             | ID         |                                                                                       |
| `householdId`                    | ID         | Owner.                                                                                 |
| `label`                          | string     |                                                                                       |
| `kind`                           | enum       | `mortgage`, `autoLoan`, `studentLoan`, `creditCard`, `personalLoan`, `heloc`, `other` |
| `currentBalance`                 | Money      |                                                                                       |
| `interestRate`                   | Rate       | **Nominal, and used nominally**: the amortization schedule runs on the contract's own terms. Converted to real only for comparison (§4.4's `highInterestDebt` step) and when the resulting payment enters the real-dollar pipeline. See below. |
| `monthlyPayment`                 | Money      | **Authoritative for cash flow** — what actually leaves the account each month.        |
| `monthlyEscrowAmount`            | Money?     | The non-amortizing portion of `monthlyPayment`: property tax, homeowners insurance, PMI, or HOA collected by the servicer. Null when the payment is principal and interest only. `principalAndInterest = monthlyPayment − (monthlyEscrowAmount ?? 0)` is what actually amortizes the loan. |
| `originationDate` / `termMonths` | date / int | Together yield the payoff year.                                                       |
| `securedAssetId`                 | ID?        |                                                                                       |
| `isTaxDeductibleInterest`        | bool       | Mortgage interest and student loan interest, subject to limits.                       |
| `linkedExpenseItemId`            | ID?        | Prevents double-counting the payment.                                                 |

**Payoff changes the FIRE number.** A mortgage retiring in 2041 removes a large
recurring expense at a known date, which lowers required annual spending in retirement
and therefore the FIRE number. Modeling the debt (rather than an eternal expense line)
is what makes that fall out automatically.

**Amortize nominally, then deflate.** A loan's schedule is fixed by the lender in
nominal terms: a $400,000 30-year note at 6% carries a ~$2,398 principal-and-interest
payment and retires in exactly 360 months, and inflation changes neither fact.
Amortizing at a *real* rate instead would produce a different payment, a different
principal/interest split, and a different payoff date — and since payoff is what drops
a large expense line, that error lands straight on the FIRE number.

So the engine amortizes on nominal terms and deflates the result into today's dollars
for each projected year of the §4 pipeline. The payment's real value therefore declines
across the life of the loan. That is not an artifact to correct — it is the genuine
benefit of carrying fixed-rate debt through inflation, and a model denominated in real
dollars should show it. Where a real rate is needed for comparison, it is the exact
Fisher conversion `(1 + interestRate) / (1 + generalInflationRate) − 1`, not simple
subtraction; the gap between the two compounds over a 30-year term.

**The payment fields are over-determined, and `monthlyPayment` wins.** `currentBalance`,
`interestRate`, `monthlyPayment`, and `originationDate`/`termMonths` are entered
independently and routinely disagree — real statement payments bundle escrow, and users
round. The payoff date is therefore **derived** from `currentBalance`, `interestRate`,
and `principalAndInterest` rather than trusted from `termMonths`; where the derived
payoff and `termMonths` disagree materially, warn and keep the derived figure, matching
the "warn, don't block" posture of invariants 4 and 6 (§12).

**Escrow must not be double-counted.** Everything inside `monthlyPayment`, including
the `monthlyEscrowAmount` portion, is already in the cash-flow pipeline through this
`Liability`. The same property tax or insurance must not also appear as its own
`ExpenseItem` — the identical hazard `linkedExpenseItemId` exists to prevent for the
payment itself (invariant 7).

### 3.7 ExpenseCategory and ExpenseItem

A two-level structure: meta-category groups related sub-category items.

**ExpenseCategory:** `id`, `householdId`, `label`, `metaCategory` (`housing`,
`transportation`, `food`, `health`, `childcare`, `discretionary`, `insurance`,
`debtService`, `education`, `misc`), `defaultRelativeInflation`.

**ExpenseItem:**

| Field                   | Type   | Notes                                                                                                       |
|-------------------------|--------|-------------------------------------------------------------------------------------------------------------|
| `id`                    | ID     |                                                                                                             |
| `householdId`           | ID     | Owner.                                                                                                       |
| `categoryId`            | ID     | Exactly one.                                                                                                |
| `label`                 | string |                                                                                                             |
| `amount`                | Money  |                                                                                                             |
| `frequency`             | enum   | `monthly`, `quarterly`, `annual`: normalized to annual on save. A one-off amount is a `OneTimeEvent` (§3.8), not an `ExpenseItem` — there is no `oneTime` frequency here. |
| `startYear` / `endYear` | int?   | Daycare for six years, a mortgage until 2041, college for four.                                             |
| `relativeInflationRate` | Rate   | **Real, relative to general inflation.** Healthcare ≈ +2.5%; groceries ≈ 0%; consumer electronics negative. |
| `phase`                 | enum   | `preRetirementOnly` \| `postRetirementOnly` \| `both`                                                       |
| `postRetirementAmount`  | Money? | For `both` items whose amount changes at retirement.                                                        |
| `linkedLiabilityId`     | ID?    | If set, the item's lifetime is the debt's amortization.                                                     |

**The `phase` field is what makes the FIRE number reflect actual retirement spending,
not current spending.** Retirement spending is a different number from today's:
commuting, work clothes, childcare, and payroll-driven savings disappear, while
healthcare rises sharply (a pre-Medicare early retiree buys ACA coverage, whose net
cost depends on MAGI relative to the federal poverty level and can swing by five
figures depending on withdrawal strategy). The FIRE number must be built from projected
retirement spending.

### 3.8 OneTimeEvent

| Field             | Type   | Notes                                                                                       |
|-------------------|--------|---------------------------------------------------------------------------------------------|
| `id`              | ID     |                                                                                             |
| `householdId`     | ID     | Owner.                                                                                       |
| `label`           | string |                                                                                             |
| `year`            | int    |                                                                                             |
| `amount`          | Money  | Signed: positive inflow, negative outflow.                                                  |
| `kind`            | enum   | `inheritance`, `homeSale`, `tuition`, `majorRepair`, `vehiclePurchase`, `windfall`, `other` |
| `accountId`       | ID?    | Destination for an inflow; **source for an outflow**. Required for outflows (invariant 15): where the $40,000 for a truck comes from changes the projection materially, and only the user knows. If the named account can't cover an outflow, the remainder falls through to that year's `netSurplus` and the reverse-waterfall drawdown (§4.4), flagging `shortfall`. |
| `taxTreatment`    | enum   | `nonTaxable`, `ordinaryIncome`, `capitalGainShortTerm`, `capitalGainLongTerm`: the two capital-gain kinds feed `realizedShortTermGains`/`realizedLongTermGains` in §4.3 respectively. |

### 3.9 AssetClass and Assumptions

**AssetClass:** `id`, `label` (`usStocks`, `intlStocks`, `bonds`, `reit`, `cash`,
`crypto`), `expectedRealReturn`, `pessimisticRealReturn`, `optimisticRealReturn`,
`incomeYield`, `qualifiedIncomeFraction`, `volatility` (reserved for future Monte Carlo).

**`incomeYield` decomposes the return; it does not add to it.** Total return arrives in
two forms with different tax treatment: distributions (dividends, interest) taxed in the
year received even when reinvested, and appreciation taxed only when realized. For each
band:

```
incomeReturn       = incomeYield                     // identical across all three bands
appreciationReturn = <band>RealReturn − incomeYield
```

Adding this field must not move any projected balance: a 5% `expectedRealReturn` with a
1.3% `incomeYield` is 3.7% appreciation, **not** 6.3% of total return. `incomeYield` is a
ratio of income to balance rather than a growth rate, so it needs no real/nominal
conversion — applied to a real balance it produces real income.

One yield serves all three bands because distribution yields are far more stable than
total returns; the band spread lives almost entirely in appreciation. Where
`pessimisticRealReturn < incomeYield`, appreciation goes negative, which is both
permitted and realistic — a bad year still pays its dividend while the principal falls.

`qualifiedIncomeFraction` is the portion of the yield taxed at preferential rates (§4.3's
`qualifiedDividends`), the remainder being ordinary income. It sits near 1.0 for broad
stock funds and at 0 for `bonds` and `cash`, whose interest is always ordinary. `reit` is
the reason the field has to exist: REIT distributions are largely ordinary income rather
than qualified dividends, so a REIT-heavy taxable account carries a materially higher tax
drag than its headline yield suggests.

**Assumptions** (per `Scenario`):

| Field                         | Notes                                                               |
|-------------------------------|---------------------------------------------------------------------|
| `generalInflationRate`        | Display and input conversion only (§1.1).                           |
| `safeWithdrawalRate`          | Real. Default 0.04.                                                 |
| `contributionWaterfall`       | `WaterfallStep[]` (§4.4): an ordered permutation of the fixed step-kind vocabulary. **Not account IDs** — each step sweeps every eligible account of that kind across the household. |
| `withdrawalOrder`             | `WithdrawalSource[]` (§8.4): an ordered list of tax-character source kinds. **Not account IDs**, for the same reason as `contributionWaterfall`. |
| `highInterestDebtThresholdRate` | **Real** rate, default 0.06. A `Liability` whose real rate (§3.6) exceeds this is paid down by the `highInterestDebt` waterfall step (§4.4) ahead of Roth/401(k)/brokerage funding. Real rather than nominal so it compares like-for-like against `AssetClass` real returns — paying down debt is an investment decision, and both sides of that comparison have to be in the same units (§1.1). Fixed rather than derived from the active band's return, so a plan's debt strategy doesn't silently differ between its pessimistic and optimistic projections. |
| `includeSocialSecurity`       | bool, default true. Scenario-level master switch: when false, no person's benefit is counted anywhere (§4.3, §8.4) regardless of their own `includeInProjection` (§3.11). Both must be true for a benefit to appear — the scenario flag answers "what if Social Security isn't there at all," the per-person flag answers "I count on mine but not my spouse's." |
| `capitalGainsRealizationRate` | Fraction of taxable-account gains realized annually pre-retirement. |
| `projectionHorizonAge`        | Default 95: the age the portfolio must survive to.                  |
| `acaMagiCeilingPercentOfFPL`  | Default 200%. Pre-65 MAGI ceiling for subsidy-aware withdrawal ordering (§8.4). |
| `taxYearId`                   | Which bundled ruleset to project under.                             |

### 3.10 Scenario

A **named, saved set of `Assumptions`** applied to the household, comparable side by
side against other scenarios. "Retire in Colorado at 55", "coast from 45", "one income
for three years" are scenarios.

`id`, `householdId`, `label`, `assumptions`, `overrides` (sparse per-entity field
overrides so a scenario can change one expense or one retirement age without cloning
the household), `createdAt`.

### 3.11 SocialSecurityBenefit

| Field                          | Notes                                                 |
|--------------------------------|-------------------------------------------------------|
| `personId`                     |                                                       |
| `estimatedMonthlyBenefitAtFRA` | From the user's SSA statement.                        |
| `claimingAge`                  | 62–70, whole years (consistent with the engine's annual granularity, §1.2). |
| `includeInProjection`          | bool: users vary in whether they want to count on it. |

**Claiming-age adjustment.** `estimatedMonthlyBenefitAtFRA` is the benefit at full
retirement age (FRA); claiming earlier or later than FRA changes the actual monthly
amount, and FRA itself depends on birth year (66 for anyone born 1943–1954, rising in
two-month steps to 67 for anyone born 1960 or later):

```
fraMonths      = TaxYear.socialSecurityFRAByBirthYear[birthYear]   // in months, e.g. 794 = 66y 2mo
claimingMonths = claimingAge × 12

monthsEarly    = max(0, fraMonths − claimingMonths)
monthsLate     = max(0, claimingMonths − fraMonths)

adjustmentFactor = 1 − min(monthsEarly, 36) × (5/9 %/mo)
                     − max(0, monthsEarly − 36) × (5/12 %/mo)
                     + monthsLate × (2/3 %/mo)

adjustedMonthlyBenefit = estimatedMonthlyBenefitAtFRA × adjustmentFactor
```

The result is a real monthly figure that then stays **flat** for the rest of the
projection: real dollars throughout (§1.1) already assumes COLA tracks inflation, so
no further real growth or decay applies once claimed. This computation runs once, at
`claimingAge`; §4.3 and §8.4 consume `adjustedMonthlyBenefit`, never
`estimatedMonthlyBenefitAtFRA` directly. Assumes birth year 1943 or later — the
phased-in pre-1943 delayed-credit rates are out of scope for a FIRE calculator's
realistic user base.

Early retirees stop paying in decades before FRA, which reduces the *`estimatedMonthlyBenefitAtFRA`
figure itself* relative to the SSA statement's projection (that statement assumes
continued earnings) — a separate effect from the claiming-age adjustment above, and
one the engine doesn't correct for. A disclosure is required wherever this figure is
shown.

### 3.12 TaxYear (reference data)

Versioned, bundled, immutable. Composed of:

- `federalBrackets[filingStatus]`: ordinary income
- `federalLtcgBrackets[filingStatus]`: 0% / 15% / 20% preferential rates
- `standardDeduction[filingStatus]`, plus the additional deduction for age 65+
- `socialSecurityWageBase`, `oasdiRate` (0.062), `medicareRate` (0.0145)
- `additionalMedicareThreshold[filingStatus]`: statutory, **not indexed**
- `niitThreshold[filingStatus]`, `niitRate` (0.038): statutory, **not indexed**
- `socialSecurityTaxabilityThresholds[filingStatus]`: the `{lower, upper}` provisional-income
  thresholds from §4.3 ($25,000/$34,000 single, $32,000/$44,000 joint as of this writing;
  $0/$0 for `marriedFilingSeparately`). Statutory, **not indexed** — the same category as
  the Additional Medicare Tax and NIIT thresholds above (§7.4).
- `socialSecurityFRAByBirthYear`: full retirement age in months, by birth year (§3.11)
- `contributionLimits`: 401(k) elective deferral, total 415(c), IRA, HSA
  self/family, plus catch-up amounts and their eligibility ages
- `earlyWithdrawalPenaltyRate` (0.10): applied to tax-deferred and unqualified Roth
  withdrawals before 59½ (§8.3, §8.4)
- `childTaxCreditPerChild`, `childTaxCreditPhaseOutThreshold[filingStatus]`,
  `childTaxCreditPhaseOutPerThousand`: the credit and its phase-out (§4.3)
- `childTaxCreditRefundablePerChild`, `childTaxCreditRefundableRate`,
  `childTaxCreditRefundableEarnedIncomeFloor`: the refundable-portion cap, the fraction
  of earned income above the floor that can be refunded, and that floor (§4.3). Other
  federal credits (Saver's Credit, Child and Dependent Care Credit, education credits,
  EITC) are out of scope (§13).
- `stateRules[stateCode]`: bracket table or flat rate, standard deduction and/or
  personal exemption, retirement-income exclusions, whether it conforms to federal
  treatment of pre-tax deferrals
- `localRules[localityCode]`
- `rmdAgeByBirthYear`
- `rmdDivisorTable[age]`: the IRS Uniform Lifetime Table divisor for each age, used
  to compute the required distribution amount each year (`balance ÷ divisor`)
- `federalPovertyLevel[householdSize]`: for ACA premium tax credit estimation

### 3.13 ProjectionSnapshot

A **frozen, timestamped copy of a projection's headline output**, persisted so a
later run can be compared against it. See §10 for why this exists and how it's
triggered.

| Field | Type | Notes |
|---|---|---|
| `id` | ID | |
| `scenarioId` | ID | Snapshots track one scenario's trajectory over time, not the whole household. |
| `asOfDate` | date | The real calendar date this snapshot was taken. |
| `trigger` | enum | `auto` \| `manual`. |
| `label` | string? | User-supplied, for manual checkpoints ("Before the house purchase"). |
| `inputDigest` | string | A cheap fingerprint (hash) of the household + scenario input state at that moment. Used to skip writing a new auto-snapshot when nothing has actually changed. |
| `retirementYear` | {pessimistic, expected, optimistic: int \| `notReachable`} | Frozen per-band result. |
| `fireNumber` | Money | |
| `netWorth` / `liquidNetWorth` / `investableNetWorth` / `afterTaxLiquidNetWorth` | Money | All four measures from §5, so §10.2's comparison can report a delta on each. |
| `savingsRate` | Rate | |

A snapshot stores **outputs only**, not a full copy of the household's input state.
That keeps it small enough (a handful of scalars) that a daily cadence over years of
use is not a meaningful storage concern under local-only storage (§1.4), unlike a
frozen copy of every `Account`/`ExpenseItem`/etc. would be. The cost of that choice:
a snapshot can tell you *that* the retirement year moved, not *why* (see §10 and the
attribution item in §13).

---

## 4. The annual cash-flow pipeline

Computed per projected year. Order matters: each tax must be computed against the
correct base.

### 4.1 Gross and payroll-tax wages

Per **Person**:

```
grossWages      = Σ IncomeStream.grossAnnualAmount  where kind ∈ {w2Wages, bonus, rsuVesting}
seEarnings      = Σ IncomeStream.grossAnnualAmount  where kind = selfEmployment
section125      = Σ resolvedAmount(Contribution)    where reducesFicaWages = true
ficaWages       = grossWages − section125
```

**"Wage-like" means `w2Wages`, `bonus`, and `rsuVesting`**: all three are FICA/Medicare
wages, unlike `rentalNet` and `pension` (income-tax-only, no FICA — they enter §4.3 as
`rentalIncome` and `pensionIncome`) or `selfEmployment` (its own payroll-tax treatment,
§4.2).
`other` is not wage-like by default; classify it explicitly per stream.

### 4.2 Payroll taxes (per person, then summed)

```
oasdi              = 0.062  × min(ficaWages, TaxYear.socialSecurityWageBase)
medicare           = 0.0145 × ficaWages                                        // uncapped

seNetEarnings      = seEarnings × 0.9235
seOasdiBase        = min(seNetEarnings, max(0, TaxYear.socialSecurityWageBase − ficaWages))
seOasdi            = 0.124  × seOasdiBase              // shares the wage-base cap with ficaWages
seMedicare         = 0.029  × seNetEarnings                                    // uncapped
seTax              = seOasdi + seMedicare
seDeduction        = seTax / 2                                                 // above-the-line
```

**The SE OASDI cap is shared with W-2 wages, per person**: a person with $150,000 of
`ficaWages` and $50,000 of `seNetEarnings` has only `socialSecurityWageBase − 150,000` of
remaining OASDI room for the SE income, not a second independent cap — otherwise a dual
W-2-plus-side-income earner would be overtaxed. This is on top of, not instead of, each
**person** getting their own cap (never a household-level figure).

Per **TaxUnit** (because the threshold is a filing-status figure applied to combined
wages *and* self-employment income):

```
addlMedicare    = 0.009 × max(0, Σ (ficaWages + seNetEarnings) − TaxYear.additionalMedicareThreshold[status])
```

**FICA is a flat rate up to an annually indexed wage base, assessed per earner**: two
spouses each get their own cap, so this must never be computed as a household-level
bracket table (that would overtax dual high earners). **Medicare is a flat, uncapped
rate on both wages and self-employment earnings**, plus the 0.9% Additional Medicare Tax
above $200,000 single / $250,000 joint, itself assessed on wages and self-employment
income combined.

### 4.3 Income taxes (per TaxUnit)

**Social Security taxability** (only relevant once a person in the `TaxUnit` has
reached `claimingAge`, §3.11 and §8.4):

```
ssBenefits        = 0                                        if not Assumptions.includeSocialSecurity
                   = Σ over persons in this TaxUnit past claimingAge with includeInProjection:
                       12 × adjustedMonthlyBenefit                       // §3.11

rentalIncome      = Σ IncomeStream.grossAnnualAmount where kind = rentalNet
pensionIncome     = Σ IncomeStream.grossAnnualAmount where kind = pension
otherStreamIncome = Σ IncomeStream.grossAnnualAmount where kind = other

inAccountInvestmentIncome = Σ over Accounts where taxTreatment = taxable:
                              balance × blendedIncomeYield          // §3.9, blended per §3.4's
                                                                    // allocationMode
qualifiedDividends        = Σ over those same accounts:
                              balance × blendedIncomeYield × blendedQualifiedIncomeFraction
ordinaryInAccountIncome   = inAccountInvestmentIncome − qualifiedDividends

nonSSIncome       = Σ grossWages
                  + seEarnings − seDeduction
                  + rentalIncome + pensionIncome + otherStreamIncome
                  + ordinaryInAccountIncome
                  + realizedShortTermGains
                  + realizedLongTermGains + qualifiedDividends
                  − Σ resolvedAmount(Contribution) where reducesFederalTaxableIncome
                  − deductibleStudentLoanInterest

provisionalIncome = nonSSIncome + 0.5 × ssBenefits   // tax-exempt interest omitted: not modeled (§13)

lower, upper      = TaxYear.socialSecurityTaxabilityThresholds[status]

taxableSS         = 0                                                                     if provisionalIncome ≤ lower
                   = min(0.5 × ssBenefits, 0.5 × (provisionalIncome − lower))              if lower < provisionalIncome ≤ upper
                   = min(0.85 × ssBenefits,
                         0.85 × (provisionalIncome − upper)
                           + min(0.5 × ssBenefits, 0.5 × (upper − lower)))                  if provisionalIncome > upper
```

`marriedFilingSeparately` filers who lived with their spouse at any point in the year
get `lower = upper = 0` in `TaxYear.socialSecurityTaxabilityThresholds` — up to 85% of
benefits is taxable regardless of income. The app doesn't currently ask about
cohabitation, so this threshold applies unconditionally for that filing status (correct
for the common case, and conservative rather than an understatement for the uncommon
one).

**Only taxable accounts throw off currently-taxable income.** `inAccountInvestmentIncome`
sums over `taxTreatment = taxable` accounts alone: distributions inside `taxDeferred`,
`roth`, and `hsaTriple` accounts are not taxed in the year received, which is the entire
point of those wrappers. The income is assumed reinvested — it stays in the account and
compounds, so no balance changes — but it is taxed annually regardless, and that tax is
paid out of cash flow. This is the same asymmetry that `capitalGainsRealizationRate`
creates for realized gains (§4.4).

`rentalIncome` counts toward NIIT on the assumption of a passive landlord, which is the
typical case here. Rental activity rising to a trade or business the taxpayer materially
participates in would be excluded; that distinction is not modeled.

```
federalAGI      = nonSSIncome + taxableSS

deduction       = max(TaxYear.standardDeduction[status] + age65Additional, itemized)
fedTaxable      = max(0, federalAGI − deduction)

ordinaryPortion     = max(0, fedTaxable − realizedLongTermGains − qualifiedDividends)
preferentialPortion = fedTaxable − ordinaryPortion   // ≡ min(realizedLongTermGains +
                                                     // qualifiedDividends, fedTaxable); the two
                                                     // portions always sum to fedTaxable
ordinaryTax     = applyBrackets(ordinaryPortion, TaxYear.federalBrackets[status])
ltcgTax         = applyStackedBrackets(preferentialPortion,
                                       stackedOn = ordinaryPortion,
                                       TaxYear.federalLtcgBrackets[status])

netInvestmentIncome = inAccountInvestmentIncome + rentalIncome
                    + realizedShortTermGains + realizedLongTermGains
                      // pensionIncome and otherStreamIncome are excluded structurally, not by
                      // prose. Wages, self-employment earnings, Social Security, and traditional
                      // retirement-account distributions are likewise NOT investment income —
                      // but they do raise federalAGI, so they can push a household over the
                      // threshold and expose investment income that would otherwise escape it.

niitBase        = min(netInvestmentIncome, max(0, federalAGI − TaxYear.niitThreshold[status]))
niit            = 0.038 × niitBase

taxBeforeCredits   = ordinaryTax + ltcgTax + niit

qualifyingChildren = count of dependents whose birthYear makes them under age 17 in the tax year
earnedIncome       = Σ over persons in this TaxUnit (grossWages + seNetEarnings)

ctcPhaseOut        = ceil(max(0, federalAGI − TaxYear.childTaxCreditPhaseOutThreshold[status]) / 1000)
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

**The Child Tax Credit is only partly refundable.** The non-refundable portion cannot
push `federalTax` below zero. Beyond it, the refundable portion is capped per child
*and* limited to a fraction of earned income above a floor — so `federalTax` can go
negative (a genuine refund), but only by that bounded amount. Treating the CTC as one
unlimited credit would materially overstate the benefit in exactly the low-income years
that Coast and Barista FIRE scenarios (§9.2, §9.3) are built around, where a household
with several children and little tax liability would otherwise appear to collect the
full credit as cash.

State and local follow the same shape against `TaxYear.stateRules[stateCode]`, using
the state's own conformity flags, deduction, exemptions, and retirement-income
exclusions. Nine states levy no income tax; several are flat; localities (NYC,
Philadelphia, Ohio municipalities, Maryland counties) add their own layer.

```
totalTaxOwed    = federalTax + stateTax + localTax
                + Σ over persons (oasdi + medicare + seTax) + addlMedicare
```

Taxable income is computed **after the standard (or itemized) deduction**: applying
brackets directly to gross income would materially overstate tax for every user. The
long-term capital gains rate schedule is included, since it is one of the largest
levers available to an early retiree (many pay 0% on realized gains) as is NIIT.

### 4.4 Surplus and where it goes

```
grossIncome     = Σ over persons (grossWages + seEarnings)   // wages, salaries, profits
                + rentalIncome + pensionIncome + otherStreamIncome   // received as cash
                + Σ over taxUnits ssBenefits                 // the FULL benefit received,
                                                             // not just the taxable portion
                                                             // NB: no inAccountInvestmentIncome —
                                                             // see below

preTaxContribs  = Σ resolvedAmount(Contribution) where taxTreatment = taxDeferred or hsaTriple
postTaxContribs = Σ resolvedAmount(Contribution) where taxTreatment = roth
annualExpenses  = Σ ExpenseItem active this year (see §3.7 for phase and lifetime)

netSurplus      = grossIncome − preTaxContribs − totalTaxOwed − postTaxContribs − annualExpenses
```

**`grossIncome` is a cash-flow measure, not the tax measure.** It is every form of
earnings the household actually receives this year before any deductions or taxes. It
differs from `federalAGI` (§4.3) deliberately and in both directions — it counts the
*full* Social Security benefit where AGI counts only the taxable slice, and it excludes
two things that would otherwise be counted twice:

- **Employer match is not gross income.** It never passes through the household's cash
  flow; §6 applies it straight to account balances after the pipeline runs. Counting it
  here would inflate both `netSurplus` and `savingsRate` with money the household never
  had to allocate. (`savingsRate` therefore measures employee contributions only — a
  deliberate choice, and a conservative one.)
- **Investment income generated inside accounts is not gross income.** Neither realized
  gains (`capitalGainsRealizationRate`) nor distributions (`inAccountInvestmentIncome`,
  from `incomeYield` — §3.9) leave the account, and §6's growth step has already credited
  both to the balance. Treating either as inflow would let the waterfall re-invest
  dollars that are already sitting there. Note the deliberate asymmetry: both still
  generate tax, which flows through `totalTaxOwed` and reduces `netSurplus` — correct,
  because the household really does pay that tax out of cash flow.

`rentalNet` enters as a net figure by construction (§3.3) rather than gross of rental
expenses, which is a small departure from "before any deductions" but is what the field
holds.

This is why income received *outside* accounts (`rentalIncome`, `pensionIncome`,
`otherStreamIncome`) and investment income generated *inside* them
(`inAccountInvestmentIncome`) are separate terms rather than one bucket: the three
consumers of that income each need a different subset of it. `federalAGI` takes all of
it, NIIT takes the investment portion but not pensions, and `grossIncome` takes the
externally-received portion but not the in-account portion. No single aggregate can
serve all three, and collapsing them into one forces the distinction into prose that an
implementer will miss.

The surplus isn't simply reinvested as one lump sum: the *order* in which money is
allocated changes the outcome, so it is routed through a configurable
**contribution waterfall**: `Assumptions.contributionWaterfall`, an ordered list of
`WaterfallStep` values (§3.9). The waterfall is a **household-level** list of step
*categories*, not a per-person priority order and not a list of account IDs: each
step sweeps every eligible account across every person in the household
simultaneously, rather than exhausting one person's accounts before considering
another's.

`WaterfallStep` is a fixed vocabulary; the default order is all seven, in this sequence:

1. `employerMatch` — capture the full match (never leave it on the table)
2. `hsaToLimit` — HSA to limit (triple tax advantage)
3. `highInterestDebt` — principal paydown on every `Liability` whose real rate (§3.6)
   exceeds `Assumptions.highInterestDebtThresholdRate`, **highest real rate first
   (avalanche), not pro rata** — clearing a 22% card before a 7% student loan is
   strictly better, so this step overrides the pro-rata rule below
4. `cashBufferToTarget` — every account with `targetBalanceMonths` set (§3.4), up to
   `targetBalanceMonths × annualExpenses / 12` each; skipped once at target (§4.5)
5. `rothToLimit` — Roth IRA / backdoor Roth to limit
6. `traditional401kToLimit` — remaining 401(k)/403(b)/TSP to elective deferral limit
7. `taxableBrokerage` — the remainder

A scenario's `contributionWaterfall` reorders or omits these steps; it cannot invent
new ones.

Each step is capped by the relevant `TaxYear.contributionLimits` for that account's
`personId`, including catch-up if that person's age ≥ 50. **If the surplus remaining
when a step is reached can't fully fund every account in that step, it is split pro
rata across those accounts by their remaining room** (e.g. two spouses' 401(k)s in
step 6 split a shortfall proportionally rather than one being funded first). This
keeps the waterfall a single flat list without needing an explicit priority order
between people, while still respecting each person's individual limits.

**If `netSurplus` is negative**, the waterfall runs in reverse as a drawdown, and the
year is flagged `shortfall` in the results so the UI can surface it rather than
silently showing a smaller number.

### 4.5 The cash buffer

An emergency fund is a **target balance**, not a recurring flow. Modeling it as a
perpetual annual contribution (alongside something like a Roth IRA) would drain decades
of surplus that should have been invested, since it never stops taking new money.

Modeled as: an `Account` (typically `cashSavings`) with `targetBalanceMonths` set
(§3.4). Its Money target for the year is `targetBalanceMonths × annualExpenses / 12`,
recomputed every projected year since `annualExpenses` moves. The `cashBufferToTarget`
waterfall step (§4.4) tops it up until `balance` reaches that target, then skips it —
the buffer stops drawing on surplus once funded, rather than competing with Roth/401(k)
contributions indefinitely. It refills automatically after a shortfall year draws it
down, since the step re-evaluates the gap every year.

---

## 5. Derived quantities

| Quantity                   | Definition                                                                                                                           |
|----------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| `taxableIncome`            | Per §4.3, per TaxUnit. **Not** a single household figure, and not the base for FICA.                                                 |
| `netWorth`                 | Σ Account.balance + Σ Asset.currentValue − Σ Liability.currentBalance                                                                |
| `liquidNetWorth`           | Σ Account.balance + Σ Asset.currentValue where `isLiquid` − Σ unsecured Liability.currentBalance                                     |
| `investableNetWorth`       | `liquidNetWorth` excluding the cash buffer target                                                                                    |
| `afterTaxLiquidNetWorth`   | `liquidNetWorth` − estimated tax on unrealized gains and on future tax-deferred withdrawals (§8.2)                                   |
| `annualExpenses`           | Σ active ExpenseItems for the year, at the year's `phase`                                                                            |
| `retirementAnnualExpenses` | Σ ExpenseItems with `phase` in {`postRetirementOnly`, `both`}, at `postRetirementAmount` where set, projected to the retirement year |
| `savingsRate`              | (preTaxContribs + postTaxContribs + netSurplus) / grossIncome                                                                        |
| `fireNumber`               | §8.1                                                                                                                                 |

---

## 6. The projection engine

Every run takes an `asOfDate` (defaults to today when run live). `currentYear` is
`asOfDate.year`; `yearFraction(0)` is the remaining fraction of that calendar year
from `asOfDate` to December 31, and `1.0` for every later year.

```
for year in currentYear .. currentYear + horizon:
    frac = yearFraction(year)                    // < 1.0 only for year 0
    for each Person:
        age(year), income streams active this year, growth applied
    compute §4 pipeline on FULL-YEAR figures → taxes, contributions, surplus
    scale that year's cash flows and tax liability × frac    // frac = 1.0 after year 0
    apply employer match
    apply OneTimeEvents scheduled for this year (they're dated events)
    grow each Account by its allocation's real return × frac (for the active band)
    grow each Asset by its realAppreciationRate × frac
    amortize each Liability; retire it and its linked ExpenseItem at payoff
    recompute netWorth, liquidNetWorth, afterTaxLiquidNetWorth
    evaluate the retirement test (§8.2)
    emit YearResult
```

**Proration applies to the pipeline's results, never to its inputs.** The §4 pipeline
always runs on full annual figures, and `frac` scales what comes out. Running it on
prorated inputs instead would tax a partial year as though it were a whole one: five
months of a $200,000 salary is $83,000, and $83,000 through progressive brackets yields
a far lower effective rate than the household actually pays. The Social Security wage
base breaks the same way — a projection run in August must not hand a high earner a
fresh, unconsumed wage base for the remaining months.

Computing the full year and then taking `frac` of the result gives the right answer for
both: the household's true effective rate, applied to the part of the year that hasn't
happened yet. The earlier months are excluded rather than recomputed because they are
already reflected in the balances the user entered.

An `ExpenseItem` or `IncomeStream` whose own `startYear`/`endYear` only partially
overlaps year 0 (started in June, say) is prorated against its own overlap with the
remaining year, not against `yearFraction(0)` directly. For instance, a stream starting 
in October of year 0 counts for its 3 months, not `frac`'s share of 12. This is what
makes a projection run in August price out the remaining 5 months of the year
correctly instead of double-counting January–July income that already happened or
padding in a full year of expenses that only partly remain.

`YearResult` carries: year, per-person ages, gross income, tax breakdown by type,
contributions by account, expenses by category, surplus, all four net-worth measures,
the FIRE number for that year, and a `flags[]` array (`shortfall`,
`contributionLimitExceeded`, `bufferDepleted`, `bridgeGapDetected`).

Three `ProjectionResult`s are produced per scenario, one per return band. Every run
also writes (or updates) a `ProjectionSnapshot` per §10. The live numbers a user
sees are always a fresh recompute from current state; the snapshot is what lets a
later run be compared against this one.

---

## 7. Tax-rule versioning

### 7.1 Which year's rules
A projection runs under `Assumptions.taxYearId`, defaulting to the newest bundled
`TaxYear`.

### 7.2 Future years
Current law is held constant in real terms (§1.1): brackets, deductions, and limits
are treated as indexed, so they do not drift against real income.

### 7.3 Scheduled statutory changes
Where a change is already law with a known effective date, the `TaxYear` records it
and the engine applies it from that year forward.

### 7.4 Non-indexed thresholds
The Additional Medicare Tax threshold, the NIIT threshold, and the Social Security
benefit taxability thresholds (§3.12's `socialSecurityTaxabilityThresholds`) are all
fixed nominal figures in statute — none have ever been adjusted since enactment. In a
real-dollar model they must be **deflated** each projected year by
`generalInflationRate`, or an increasing share of users will silently cross them,
which is precisely the real-world effect and should be reflected.

### 7.5 Stale data
If the calendar year exceeds the newest bundled `TaxYear`, the app projects under the
newest available ruleset and displays a persistent, non-dismissible notice naming the
tax year in use. It must never silently imply currency it does not have.

### 7.6 State and territory coverage
`TaxYear.stateRules` covers **all 50 states and the District of Columbia** at launch,
not a partial set. This is the largest recurring data-maintenance commitment in the
app (§1.4), so it needs a repeatable acquisition process rather than one-time manual
entry:

- Each state's rules (brackets or flat rate, standard deduction / personal
  exemption, retirement-income exclusions, and whether it conforms to federal
  treatment of pre-tax deferrals) are pulled from that state's Department of Revenue
  publications for the tax year, normalized into the shared `stateRules[stateCode]`
  shape, and versioned alongside the rest of that year's `TaxYear`.
- Rules change annually, not continuously, so extraction runs once per tax year. A
  scraped or extracted pass still needs a human review before a `TaxYear` ships,
  since state DoR sites aren't uniform and bracket figures need a sanity check
  against the prior year rather than being trusted blind.

**US territories (Puerto Rico, Guam, USVI, American Samoa, Northern Mariana
Islands) are a materially different problem, not an extension of the 50-state
model, and are excluded from this launch scope.** Puerto Rico in particular runs a
tax code that is not a "mirror" of the federal system layered with state-style
brackets; it's largely a separate system with its own AGI definition. Folding it
into `stateRules[stateCode]`'s shape would misrepresent how the tax actually works,
so territory support is a distinct scope decision for later, not a checkbox on this
one.

---

## 8. Retirement determination

### 8.1 FIRE number

```
grossedUpSpending = retirementAnnualExpenses / (1 − effectiveRetirementTaxRate)
fireNumber        = grossedUpSpending / safeWithdrawalRate
```

The input is **retirement** spending, not current spending (§3.7). And the figure is
**grossed up for tax on withdrawals**: drawing $80,000 of spending from a traditional
401(k) requires withdrawing more than $80,000, because the withdrawal is ordinary
income (leaving out the gross-up would systematically understate the target for
anyone holding tax-deferred assets).

`safeWithdrawalRate` is a **real** rate (default 4%), consistent with §1.1, applied as
a standard perpetuity.

**Deriving `effectiveRetirementTaxRate` without a full iterative solve.** The naive
approach (guess a FIRE number, run the whole multi-decade decumulation simulation
(§8.4) against it, read off the resulting tax rate, adjust the guess, repeat until it
converges) is accurate but expensive: it reruns years of simulation at every
candidate year of the outer projection loop.

Instead, the rate is computed **directly from that year's actual account balances**,
in one pass, with no convergence loop. At each candidate year in the projection loop
(§6) the engine already knows the real balance in every account by `taxTreatment`.
It applies the configured `withdrawalOrder` to source exactly one year of
`retirementAnnualExpenses` from those balances, runs that single withdrawal through
the real §4.3 tax computation (exact, not approximated), and uses the resulting rate
as `effectiveRetirementTaxRate` for that year's FIRE-number check.

The tradeoff: this prices the *first* year of retirement accurately but doesn't
capture how the tax picture shifts decades in (RMDs forcing more ordinary income
later, for example). That gap is covered by the retirement test's third leg (§8.2):
the full decumulation simulation still runs to verify `projectionHorizonAge`
survival, so if the one-year estimate was too optimistic, that check catches it and
the year doesn't qualify. The cheap estimate sets the target; the full simulation
still verifies it so accuracy doesn't depend on the estimate alone.

### 8.2 The retirement test

A year qualifies when **all three** hold:

1. `afterTaxLiquidNetWorth ≥ fireNumber`
2. The bridge period is funded (§8.3)
3. The decumulation simulation survives to `projectionHorizonAge`

`afterTaxLiquidNetWorth` subtracts: capital gains tax on unrealized gains in taxable
accounts (`balance − costBasis`, at the projected LTCG rate computable now that
`costBasis` exists), and the expected ordinary-income tax on tax-deferred balances.
Roth balances are subtracted at zero.

`retirementYear` is the first qualifying year. **If no year qualifies within the
horizon, the result is explicitly `notReachable`** with the shortfall at the horizon
(not a blank, and not an arbitrarily distant year).

### 8.3 The bridge period

The gap between retiring and turning 59½, during which tax-deferred money is penalized.

**What the engine models.** A `traditional` or unqualified `rothEarnings` withdrawal
before 59½ incurs `TaxYear.earlyWithdrawalPenaltyRate` on top of ordinary income tax
(§8.4). Bridge-eligible assets are therefore the sources that escape that penalty:
`taxableBasis` and `taxableGains` (a brokerage account has no age gate) and `rothBasis`
(`rothContributionBasis` is withdrawable at any age, tax- and penalty-free).

If total bridge-eligible assets are less than cumulative spending across the bridge,
the year is flagged `bridgeGapDetected` and does not qualify even if the raw number
clears the FIRE target. This is one of the most important questions a FIRE calculator
can answer, so it needs to be modeled explicitly rather than left implicit in the
headline number.

**What it does not model: 72(t)/SEPP and the Rule of 55.** Both are real routes to
tax-deferred money before 59½ without the penalty, and neither is represented (§13).
The engine therefore treats tax-deferred balances as bridge-ineligible even where a
real household could reach them, which makes `bridgeGapDetected` deliberately
**conservative**: it can report a gap that a SEPP schedule or a well-timed separation
would in fact close. That is the safe direction for the error to run, but the UI must
say so wherever the flag appears, rather than presenting the bridge as impassable.

### 8.4 Decumulation

Post-retirement, the engine continues stepping years, withdrawing per
`withdrawalOrder`, applying RMDs at the statutory age, adding each claimed person's
`adjustedMonthlyBenefit × 12` to income at their `claimingAge` (§3.11, taxed per §4.3),
and switching healthcare costs from ACA to Medicare at 65. Survival to
`projectionHorizonAge` is the real test; the FIRE-number crossing is the headline.

`withdrawalOrder` is `Assumptions.withdrawalOrder` (§3.9): an ordered list of
`WithdrawalSource` values, not account IDs, distinguishing withdrawals by tax
character rather than by which specific account they come from:

- `rothBasis` — `rothContributionBasis`; non-MAGI, tax- and penalty-free at any age
- `taxableBasis` — cost-basis portion of a taxable-brokerage withdrawal; non-MAGI
- `traditional` — `traditional401k`/`traditionalIRA`/`tsp`/etc.; MAGI-counting, ordinary
  income. **Before 59½, also incurs `TaxYear.earlyWithdrawalPenaltyRate`** on the amount
  withdrawn (§8.3)
- `taxableGains` — realized-gain portion of a taxable-brokerage withdrawal; MAGI-counting
- `rothEarnings` — Roth balance beyond contribution basis; non-MAGI and tax-free once
  qualified (59½ *and* the 5-year rule). Before that it is ordinary income **and**
  incurs `TaxYear.earlyWithdrawalPenaltyRate`

Default order: `[rothBasis, taxableBasis, traditional, taxableGains, rothEarnings]` —
spend non-MAGI sources and ordinary taxable brokerage before touching tax-deferred or
Roth-earnings balances, preserving the accounts with the longest runway of tax-free or
tax-deferred growth for last.

**ACA subsidy-aware ordering (pre-65 only).** `rothBasis` and `taxableBasis` don't
count toward MAGI; `traditional` and `taxableGains` do, and MAGI relative to
`TaxYear.federalPovertyLevel[householdSize]` determines the ACA premium subsidy.
Rather than solving jointly for the withdrawal mix that maximizes lifetime
after-tax-and-premium spending (a real optimization problem, see §13), the default
order above becomes a **heuristic MAGI ceiling** pre-65.

**The ceiling binds only the MAGI-counting sources.** `traditional` and `taxableGains`
draws are limited to whatever keeps MAGI at or below
`Assumptions.acaMagiCeilingPercentOfFPL` of the poverty line. `rothBasis` and
`taxableBasis` are drawn freely — they never touch MAGI, so no ceiling can apply to
them — and the engine spends them first precisely so that MAGI-counting draws stay
small. Only when those non-MAGI balances are exhausted and the year's spending still
isn't covered does the engine breach the ceiling, accepting the subsidy loss rather
than under-funding the year.

This is the same rule of thumb FIRE planners apply by hand, not a true optimum, but it
captures the bulk of the available subsidy without engine complexity approaching a
linear/dynamic program. The ceiling stops applying at 65, when Medicare replaces ACA
coverage — `withdrawalOrder` reverts to its plain default sequence.

---

## 9. FIRE variants

All fall out of the same engine given two levers: `Contribution.stopYear` and
post-retirement income.

**9.1 Lean / Fat FIRE**: a scenario with different `retirementAnnualExpenses`.

**9.2 Barista FIRE**: an `IncomeStream` with a `startYear` at that Person's own
retirement, typically with employer health coverage — the user ends or reduces the
corresponding ACA `ExpenseItem` themselves (there's no structural link enforcing the
two move together, unlike `Liability.linkedExpenseItemId`).

**9.3 Coast FIRE**: set `Contribution.stopYear` on every account. The coast number is
the balance today that reaches the FIRE number by the traditional retirement age with
zero further contributions.

Reported as a **date**, interpolated within the crossing year. The engine finds the
first projected year `Y` whose coasting balance reaches the target, then interpolates
linearly between that year's opening and closing balances:

```
monthFraction = (target − coastingBalance(start of Y))
                  / (coastingBalance(end of Y) − coastingBalance(start of Y))
coastDate     = January of Y + round(monthFraction × 12) months
```

This is a **presentation-layer interpolation over an annual engine** (§1.2), not a claim
of monthly fidelity — it assumes the year's growth accrues smoothly. That assumption is
safe here specifically because the underlying quantity is a smooth compounding curve
rather than a lumpy cash flow, which is why this is the one place the model reports
sub-annual precision. It is what makes "you can stop contributing in March 2031" legible
where "2031" is not.

---

## 10. Progress tracking and snapshots

The engine (§6) always recomputes fresh from current household state, there is no
sense in which "today's projection" is a delta layered onto "January's projection."
What makes the app forward-looking across edits isn't the live projection itself,
it's a **history of `ProjectionSnapshot`s (§3.13)** that the live projection can be
compared against.

### 10.1 When a snapshot is written

**Automatic:** on every saved edit to a scenario's household state or `Assumptions`,
throttled to at most one auto-snapshot per `scenarioId` per calendar day. several
edits in one sitting collapse into a single end-of-session snapshot rather than one
per keystroke. Before writing, the engine compares `inputDigest` against the most
recent snapshot for that scenario and skips the write entirely if nothing actually
changed (e.g. the user opened the app and closed it without editing anything).

**Manual:** the user can pin a checkpoint at any time, with an optional `label`. This
is not throttled. A deliberate "save this as a checkpoint" always writes.

Because a snapshot stores only the output summary (§3.13), not a full input copy,
even years of daily auto-snapshots stay cheap under local-only storage (§1.4). No
retention/thinning policy is needed for v1.

### 10.2 Comparing snapshots

A **comparison between any two snapshots for the same `scenarioId`** is computed on
demand (it is not itself a stored entity). Given an older and a newer
`ProjectionSnapshot`, the comparison surfaces: Δ retirement year per band, Δ FIRE
number, Δ net worth (all four measures), Δ savings rate, and the elapsed time between
`asOfDate`s. This is what powers a "your retirement date has moved from 2039 to 2038
since March" view, and a net-worth-over-time / retirement-date-over-time trend chart
across all snapshots for a scenario.

**This tells the user *that* their trajectory moved, not *why*.** Decomposing a
change into its drivers (market performance on existing balances vs. new
contributions vs. an edited assumption vs. the pure passage of time) would require
re-running the projection engine with mixed old/new inputs to isolate each factor,
which is real additional engine work. It's deferred (§13) rather than built now,
consistent with how ACA withdrawal optimization (§8.4) and the FIRE-number tax rate
(§8.1) were both resolved with a cheap, honest approximation over a more accurate but
expensive one.

---

## 11. Data, privacy, and portability

- All persistence is local. No telemetry, no analytics, no crash reporting containing
  user data.
- **Export** produces a single versioned JSON file containing the full household,
  scenarios, and the `taxYearId` used with an explicit schema version for migration.
- **Import** validates against the schema version and migrates forward.
- Backup prompting is a product requirement, not a preference: local-only storage
  means an unbacked-up device loss is unrecoverable.
- Bundled `TaxYear` data is the only thing that ships in; nothing ships out.

---

## 12. Invariants

1. Every `ExpenseItem` belongs to exactly one `ExpenseCategory`.
2. Every `IncomeStream` and `Account` belongs to exactly one `Person`.
3. Every `Person` belongs to exactly one `TaxUnit`; a `marriedFilingJointly` unit has
   exactly two.
4. `Account.costBasis ≤ Account.balance` for taxable accounts (warn, do not block.
   Losses are real).
5. `rothContributionBasis ≤ balance` for Roth accounts.
6. Per-person annual contributions do not exceed `TaxYear.contributionLimits`:
   **warn and cap in projection**, do not block entry, since the user may be recording
   an actual over-contribution.
7. A `Liability` with a `linkedExpenseItemId` must not also be counted in the
   waterfall's debt step (no double-counting).
8. Rates are stored as decimals (0.05, not 5). Percent is a display concern only.
9. Money is stored in integer cents. No floats.
10. `Asset.securedByLiabilityId` and `Liability.securedAssetId` must agree.
11. `ProjectionSnapshot`s are immutable once written and are never recomputed or
    edited in place; a plan change produces a new snapshot, it doesn't rewrite
    history.
12. Every `ProjectionSnapshot.scenarioId` must reference an existing `Scenario`; a
    deleted scenario's snapshots are deleted with it.
13. `Account.allocationWeights` sums to 1.0 when `allocationMode = weighted` (§3.4).
14. Every `Asset`, `Liability`, `ExpenseCategory`, `ExpenseItem`, `OneTimeEvent`, and
    `Scenario`'s `householdId` references an existing `Household`.
15. An `OneTimeEvent` with a negative `amount` must name an `accountId` (§3.8). Inflows
    may leave it null.
16. `Liability.monthlyEscrowAmount ≤ monthlyPayment` — escrow is a portion of the
    payment, not an addition to it (§3.6).
17. `Contribution.contributionBaseStreamIds` is non-empty when `mode = percentOfGross`,
    and every id references an `IncomeStream` belonging to the same `Person` as the
    account (§3.4).

---

## 13. Deferred

- Monte Carlo simulation and historical-sequence backtesting
- Itemized deduction modeling beyond a single entered total
- Federal credits beyond the Child Tax Credit (Saver's Credit, Child and Dependent
  Care Credit, education credits, EITC) — low relevance to this app's target
  households and low dollar impact relative to the credit already modeled (§4.3, §3.12)
- Tax-exempt interest (municipal bonds) as an income kind — it is not modeled as an
  `IncomeStream` or `AssetClass`, so it is omitted from the provisional-income
  calculation in §4.3, which slightly understates taxable Social Security for anyone
  actually holding munis
- AMT
- Equity compensation beyond simple RSU vesting (ISOs, ESPP, 83(b))
- Multi-state / part-year residency
- US territories (Puerto Rico, Guam, USVI, American Samoa, Northern Mariana
  Islands) (see §7.6)
- A true joint optimizer for ACA subsidy vs. lifetime tax during decumulation,
  replacing the MAGI-ceiling heuristic in §8.4
- **72(t)/SEPP schedules and the Rule of 55** as penalty-free routes across the bridge
  period (§8.3). Neither is a flag that can simply be flipped on:
  - *72(t)/SEPP* needs the three IRS calculation methods (required minimum
    distribution, fixed amortization, fixed annuitization), each producing a different
    annual figure; the interest-rate and life-expectancy inputs those methods consume;
    a per-account election entity, since a schedule is sized against one account's
    balance and households routinely split an IRA to size it; the lock-in that fixes
    the amount once elected; and the modification rule, which retroactively applies the
    penalty to *every* distribution taken under the schedule, with interest, if it is
    broken before the longer of five years or 59½.
  - *Rule of 55* needs an employer linkage on `Account`, which does not exist today.
    The exemption reaches only the plan of the employer separated from in or after the
    year the person turns 55 — not IRAs, and not plans left behind at prior employers
    (age 50 for qualified public safety employees).
- Non-US jurisdictions
- Estate planning and inheritance tax
- Long-term care cost modeling
- Attributing a change between two `ProjectionSnapshot`s to its actual drivers
  (market performance vs. new contributions vs. an edited assumption vs. time
  passing) (§10.2 exposes the delta)
- Reverting or replaying a scenario against a prior snapshot's full input state
  (snapshots intentionally store outputs only, not a full input copy, §3.13)
