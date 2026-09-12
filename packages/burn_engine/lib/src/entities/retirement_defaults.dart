/// §3.3, §3.4.3 and §3.4.5: the spans that end at retirement without anybody
/// saying so.
///
/// A salary, a payroll deferral and a health premium all stop when the job
/// does, and the doc says each `endYear` "defaults to the year before the
/// owning Person's retirementYear". A default is not a stored value, so
/// nothing downstream can see it: `activeIn` reads the field, finds null, and
/// runs the stream to the horizon. Left unresolved, a projection pays a salary
/// to age 95, never draws on the portfolio, and reports net worth climbing
/// forever in every band.
///
/// Resolving it here, once, keeps every call site reading a plain `endYear`.
/// It happens per projected retirement year, so each candidate in §8.2's
/// search sees earned income stopping at the year being tested.
library;

import 'account.dart';
import 'household.dart';
import 'income.dart';
import 'payroll.dart';

/// The household as it stands if retirement happens in [retirementYear], with
/// every span that ends at retirement given the year it ends.
///
/// A null [retirementYear] leaves everything alone: nothing has been solved
/// yet, so there is no year to end at.
Household withRetirementDefaults(Household household, int? retirementYear) {
  if (retirementYear == null) return household;
  final last = retirementYear - 1;

  return household.copyWith(
    incomeStreams: [
      for (final s in household.incomeStreams)
        // Unearned income does not stop: a pension and a rental go on.
        if (!s.kind.isEarned || s.endYear != null)
          s
        else
          _endStream(s, last),
    ],
    payrollDeductions: [
      for (final d in household.payrollDeductions)
        if (d.endYear != null) d else _endDeduction(d, last),
    ],
    accounts: [
      for (final a in household.accounts)
        if (a.contribution.endYear != null) a else _endContribution(a, last),
    ],
  );
}

IncomeStream _endStream(IncomeStream s, int last) => IncomeStream(
      id: s.id,
      personId: s.personId,
      label: s.label,
      kind: s.kind,
      grossAnnualAmount: s.grossAnnualAmount,
      realGrowthRate: s.realGrowthRate,
      employerId: s.employerId,
      startYear: s.startYear,
      endYear: last,
      startMonth: s.startMonth,
      endMonth: s.endMonth,
      isFicaSubject: s.isFicaSubject,
      isQualifiedBusinessIncome: s.isQualifiedBusinessIncome,
      isSpecifiedServiceBusiness: s.isSpecifiedServiceBusiness,
      variability: s.variability,
    );

/// A deduction ends with the pay it comes out of, except the coverage-related
/// kinds, which end with the coverage instead (§3.4.5).
PayrollDeduction _endDeduction(PayrollDeduction d, int last) => PayrollDeduction(
      id: d.id,
      personId: d.personId,
      label: d.label,
      kind: d.kind,
      annualAmount: d.annualAmount,
      reducesFederalTaxableIncome: d.reducesFederalTaxableIncome,
      reducesStateTaxableIncome: d.reducesStateTaxableIncome,
      reducesFicaWages: d.reducesFicaWages,
      startYear: d.startYear,
      endYear: last,
    );

Account _endContribution(Account a, int last) => Account(
      id: a.id,
      personId: a.personId,
      label: a.label,
      kind: a.kind,
      taxTreatment: a.taxTreatment,
      limitFamily: a.limitFamily,
      balance: a.balance,
      costBasis: a.costBasis,
      rothContributionBasis: a.rothContributionBasis,
      rothFirstContributionYear: a.rothFirstContributionYear,
      contribution: Contribution(
        mode: a.contribution.mode,
        value: a.contribution.value,
        contributionBaseStreamIds: a.contribution.contributionBaseStreamIds,
        employerMatch: a.contribution.employerMatch,
        startYear: a.contribution.startYear,
        endYear: last,
        startMonth: a.contribution.startMonth,
        endMonth: a.contribution.endMonth,
        reducesFederalTaxableIncome:
            a.contribution.reducesFederalTaxableIncome,
        reducesStateTaxableIncome: a.contribution.reducesStateTaxableIncome,
        reducesFicaWages: a.contribution.reducesFicaWages,
      ),
      employerId: a.employerId,
      allocationMode: a.allocationMode,
      assetAllocationId: a.assetAllocationId,
      retirementAllocationId: a.retirementAllocationId,
      allocationWeights: a.allocationWeights,
      isRestrictedPurpose: a.isRestrictedPurpose,
      targetBalanceMonths: a.targetBalanceMonths,
      beneficiaryId: a.beneficiaryId,
    );
