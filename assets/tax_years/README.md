# Bundled tax years

One file per year, read at startup and parsed by
`packages/burn_engine/lib/src/taxyear/tax_year_loader.dart`. §7 promises that a
new tax year is a data change, so a new year is a new file here and no code.

Money is **integer cents** throughout, per invariant 10. A fractional cent is
refused by the loader rather than rounded.

## What is in 2026.json

Every figure is tax year 2026, from the primary sources:

| | |
|---|---|
| brackets, deductions, capital gains, §199A, the credits | Rev. Proc. 2025-32 |
| deferral, IRA, 415(c), 401(a)(17) and catch-up limits | Notice 2025-67 |
| HSA limits | Rev. Proc. 2025-19 |
| the premium tax credit table | Rev. Proc. 2025-25 |
| the poverty guidelines | HHS, January 2026 |
| Part B premiums and IRMAA tiers | CMS |
| the wage base | SSA |
| state brackets and deductions | Tax Foundation, 2026 |

All of it read on 6 September 2026.

Anything carrying `"indexed": false` is fixed by law rather than adjusted: the
NIIT and additional-Medicare thresholds ($200k/$250k), the §86 Social Security
provisional-income thresholds ($25k/$34k, $32k/$44k), the §121 exclusion
($250k/$500k), the Child Tax Credit phase-out thresholds, and the student-loan
interest cap. Likewise the rates: OASDI 6.2%, Medicare 1.45%, additional
Medicare 0.9%, NIIT 3.8%, the §199A 20%, the 10% early-withdrawal and 20% HSA
non-medical penalties, unrecaptured §1250 at 25%, and 27.5-year residential
depreciation. §7.4 asks that those be deflated each projected year rather than
carried forward at face value.

### What 2026 changed

The **enhanced premium tax credits expired** with 2025.
`acaApplicablePercentageTable` is back on the statutory schedule, where the
poorest household contributes 2.10% of income rather than nothing and the
top band pays 9.96%, and `acaMaximumFplPercent` is 400 again, so a household
a dollar over four times the poverty line receives nothing at all. For a
bridge plan this is the most consequential number in the file.

The **deduction for people 65 and over** that the 2025 act added is in
`seniorDeduction`, worth $6,000 a head. It carries `throughYear: 2028`,
which is what stops a long projection spending it in the 2030s. A tax year
that grants none leaves the field out.

## The state layer

`stateRules` covers all fifty states and the District of Columbia, from the
Tax Foundation's *2026 State Individual Income Tax Rates and Brackets*. Nine
states levy no broad income tax and carry an empty schedule. Rates,
deductions, exemptions and credits are split by filing status: each figure
is written either as one value for everybody, or as a `single` and `married`
pair, and filing separately and heads of household follow the single
schedule.

Connecticut's joint schedule was reconstructed by doubling its single
brackets, because the source table skipped a rate.

`education529` is what each state gives back for 529 contributions, taken
from each plan's or revenue department's own 2026 figures and checked
against savingforcollege.com. `cap` is the most contribution that counts,
`perBeneficiary` applies it to each child separately, `creditRate` marks a
credit rather than a deduction, and `incomeLimit` is the federal AGI above
which nothing is given. Thirteen states give nothing. The engine assumes the
household uses its own state's plan, and ignores the carry-forward that
Virginia, Ohio and Maryland allow above the cap. Where a cap is per
taxpayer, the married figure assumes both spouses contribute. Oregon's
credit depends on income and is stored at the rate for $70,000 to $100,000
of AGI, which reaches the same $190 or $380 cap as the other tiers at the
amounts a college plan puts in. Minnesota is stored as its subtraction,
since its credit phases out well below most savers' incomes.

`retirementIncomeExclusion` is zero for every state, which understates what
retirees in about thirty of them keep. Tracked in
[backlog.md](../../docs/backlog.md).

## Still estimated

`acaBenchmarkPremiumByAge` is a smooth curve standing in for a national
average, and 2026 premiums rose steeply. Anyone modelling a bridge to
Medicare should enter their own benchmark rather than trust it. Tracked in
[backlog.md](../../docs/backlog.md).

Ages 0 to 20 are derived from the age-21 figure using the federal default age
curve, which every state but a handful uses: 0.765 of a 21-year-old up to age
14, then stepping to parity at 21. Children have to be priced, because they
already count toward the household size the subsidy is measured against.

What the model deliberately leaves out is listed in §13.2 of
[domain.md](../../docs/domain.md), not here.