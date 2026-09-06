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
- `stateRules`, which covers nine no-tax states plus CO, PA and CA only

Until that check happens, treat any number the app shows as directionally right
and precisely wrong. §7.5's staleness posture applies: the app should say which
ruleset produced a figure.
