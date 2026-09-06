# Bundled tax years

One file per year, read at startup and parsed by
`packages/burn_engine/lib/src/taxyear/tax_year_loader.dart`. §7 promises that a
new tax year is a data change, so a new year is a new file here and no code.

Money is **integer cents** throughout, per invariant 10. A fractional cent is
refused by the loader rather than rounded.

## 2026.json is provisional

The figures split in two, and only one half is safe.

**Statutory and stable.** Anything carrying `"indexed": false` is fixed by law
and has not moved in years: the NIIT and additional-Medicare thresholds
($200k/$250k), the §86 Social Security provisional-income thresholds
($25k/$34k, $32k/$44k), the §121 exclusion ($250k/$500k), the Child Tax Credit
phase-out thresholds, and the student-loan interest cap. Likewise the rates:
OASDI 6.2%, Medicare 1.45%, additional Medicare 0.9%, NIIT 3.8%, the §199A 20%,
the 10% early-withdrawal and 20% HSA non-medical penalties, unrecaptured §1250
at 25%, and 27.5-year residential depreciation.

**Estimated, and needing verification before release.** Every
inflation-adjusted figure. Check each against the IRS revenue procedure for
2026 and the SSA fact sheet:

- `federalBrackets`, `federalLtcgBrackets`, `standardDeduction`
- `socialSecurityWageBase`
- `contributionLimits` for every family, and every `catchUpTiers` amount
- `annualAdditions415c`, `compensationLimit401a17`, `rothCatchUpWageThreshold`
- `rothIraIncomeLimit`, `iraDeductibilityPhaseOut`, `qbiThreshold`
- `childTaxCreditPerChild` and `childTaxCreditRefundablePerChild`
- `federalPovertyLevel` and its increment, from the HHS guidelines
- `acaBenchmarkPremiumByAge`, currently a smooth curve standing in for the
  national average, and `acaApplicablePercentageTable`
- `irmaaBrackets`, and note they are currently the same for every filing status
- `rmdAgeByBirthYear` and `rmdDivisorTable`
- the federal half of this file is still on 2025 figures, one year behind
  `stateRules` below. Refreshing it is the next data job.

Until that check happens, treat any number the app shows as directionally right
and precisely wrong. §7.5's staleness posture applies: the app should say which
ruleset produced a figure.

## The state layer

`stateRules` covers all fifty states and the District of Columbia, taken from
the Tax Foundation's *2026 State Individual Income Tax Rates and Brackets*,
read on 6 September 2026. Nine states levy no broad income tax and carry an
empty schedule.

Rates and brackets are split by filing status. A jurisdiction figure is written
either as one value for everybody, or as a `single` and `married` pair, and
filing separately and heads of household follow the single schedule. That is
what most states do, and it is the conservative reading where they do not:
several states give a head of household a wider schedule than a single filer,
so those households are shown slightly more state tax than they will owe.

What the model does not yet carry, in rough order of how much it costs a
household:

- **Retirement income exclusions.** Illinois, Pennsylvania and Mississippi
  exempt retirement income almost entirely, and around thirty states exclude
  part of it, usually with an age or income test. `retirementIncomeExclusion`
  exists but is subtracted from all income rather than from retirement income,
  so it is left at zero everywhere until it can be applied to the right
  dollars. Retirees in those states are shown more state tax than they owe.
- **Social Security.** Most states exempt it and the state layer runs off
  federal AGI, which includes whatever part of it is federally taxable.
- **Credits.** Arizona, Arkansas, California, Delaware, Iowa, Nebraska, Oregon
  and Utah give a personal credit rather than an exemption, and the model has
  only exemptions. Those credits are dropped, which overstates their tax a
  little.
- **Phase-outs.** Connecticut, Rhode Island and others taper the personal
  exemption away as income rises, and Wisconsin tapers its standard deduction.
  Both are carried flat here, which understates tax at high incomes.
- **Washington's capital gains tax**, 7% above a large exclusion, has no home in
  a model whose state layer runs on ordinary income. Washington is carried as a
  no-income-tax state, which is right for wages and wrong for a large sale.
- **Connecticut's joint schedule** was reconstructed by doubling its single
  brackets, because the source table skipped a rate.
- **Local income tax.** `localRules` is still empty, and New York City, Maryland
  counties and Ohio municipalities all levy their own.
