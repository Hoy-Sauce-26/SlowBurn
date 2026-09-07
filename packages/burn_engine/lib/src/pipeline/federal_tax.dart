/// §4.3.3 to §4.3.6. The rate schedules, the credits, and the total owed.
library;

import '../entities/assumptions.dart';
import '../entities/account.dart';
import '../entities/household.dart';
import '../enums.dart';
import '../taxyear/tax_year.dart';
import '../types.dart';
import 'brackets.dart';
import 'income_tax.dart';
import 'wages.dart';

/// The health-coverage answer §4.3.5 produces, which §4.4 spends and §8.4.4
/// steers withdrawals by.
class HealthCredit {
  final Money acaMagi;
  final int taxUnitSize;
  final double fplPercent;

  /// Zero where nobody in the unit buys their own coverage.
  final Money benchmarkPremium;
  final bool eligible;
  final Money premiumTaxCredit;

  /// Raised where the household sits below the subsidy floor: the real program
  /// pays nothing there, and the household's options are a decision (§4.3.5).
  final bool belowSubsidyFloor;

  const HealthCredit({
    required this.acaMagi,
    required this.taxUnitSize,
    required this.fplPercent,
    required this.benchmarkPremium,
    required this.eligible,
    required this.premiumTaxCredit,
    required this.belowSubsidyFloor,
  });

  /// What the household actually pays for coverage, which §4.4 books as an
  /// expense rather than a tax offset (§4.3.5).
  Money get netPremium =>
      (benchmarkPremium - premiumTaxCredit).orZeroIfNegative;
}

/// Everything §4.3 owes, for one tax unit in one year.
class TaxOwed {
  final Money ordinaryPortion;
  final Money preferentialPortion;
  final Money ordinaryTax;
  final Money ltcgTax;
  final Money netInvestmentIncome;
  final Money niit;
  final Money recaptureTax;
  final Money taxBeforeCredits;

  final Money childTaxCredit;
  final Money federalTax;

  final Money stateTax;
  final Money localTax;
  final Money payrollTax;
  final Money additionalMedicareTax;
  final Money withdrawalPenalty;

  final HealthCredit health;

  const TaxOwed({
    required this.ordinaryPortion,
    required this.preferentialPortion,
    required this.ordinaryTax,
    required this.ltcgTax,
    required this.netInvestmentIncome,
    required this.niit,
    required this.recaptureTax,
    required this.taxBeforeCredits,
    required this.childTaxCredit,
    required this.federalTax,
    required this.stateTax,
    required this.localTax,
    required this.payrollTax,
    required this.additionalMedicareTax,
    required this.withdrawalPenalty,
    required this.health,
  });

  /// §4.3.6. One figure the pipeline spends.
  Money get totalTaxOwed =>
      federalTax +
      stateTax +
      localTax +
      payrollTax +
      additionalMedicareTax +
      withdrawalPenalty;
}

/// What §8.4.1 charges for reaching money early, summed for this tax unit.
class WithdrawalPenalties {
  /// Tax-deferred and unqualified Roth earnings drawn before 59½.
  final Money earlyRetirementDraws;

  /// HSA money spent on anything but medical, before 65.
  final Money hsaNonMedicalDraws;

  const WithdrawalPenalties({
    this.earlyRetirementDraws = Money.zero,
    this.hsaNonMedicalDraws = Money.zero,
  });

  Money penalty(TaxYear taxYear) =>
      earlyRetirementDraws * taxYear.earlyWithdrawalPenaltyRate +
      hsaNonMedicalDraws * taxYear.hsaNonMedicalPenaltyRate;
}

TaxOwed computeTaxOwed(
  TaxUnit unit, {
  required Household household,
  required TaxableIncome income,
  required List<PersonWages> wages,
  required Assumptions assumptions,
  required TaxYear taxYear,
  required int year,
  required int currentYear,
  YearInputs inputs = const YearInputs(),
  WithdrawalPenalties penalties = const WithdrawalPenalties(),
}) {
  final status = unit.filingStatus;
  final inflation = assumptions.generalInflationRate;
  final people = household.peopleIn(unit).toList();
  final personIds = {for (final p in people) p.id};
  final unitWages = wages.where((w) => personIds.contains(w.personId)).toList();

  Money threshold(Indexed i) =>
      i.realValueIn(year, currentYear: currentYear, inflation: inflation);

  // --- §4.3.3 --------------------------------------------------------------
  final ordinaryPortion =
      (income.fedTaxable - income.netCapitalGain).orZeroIfNegative;
  final preferentialPortion = income.fedTaxable - ordinaryPortion;

  final ordinaryTax =
      applyBrackets(ordinaryPortion, taxYear.federalBrackets[status]!);
  final ltcgTax = applyStackedBrackets(
    preferentialPortion,
    stackedOn: ordinaryPortion,
    brackets: taxYear.federalLtcgBrackets[status]!,
  );

  // Wages, self-employment earnings, Social Security and traditional
  // distributions are not investment income. They still raise federalAgi, so
  // they can expose investment income that would otherwise escape the surtax.
  final netInvestmentIncome = income.inAccountInvestmentIncome +
      income.taxableRental +
      income.realizedShortTermGains +
      income.realizedLongTermGains +
      inputs.assetSaleRecapture;
  final niitBase = minMoney(
    netInvestmentIncome,
    (income.federalAgi - threshold(taxYear.niitThreshold[status]!))
        .orZeroIfNegative,
  );
  final niit = niitBase.orZeroIfNegative * taxYear.niitRate;

  final recaptureTax =
      inputs.assetSaleRecapture * taxYear.unrecapturedSection1250Rate;

  final taxBeforeCredits = ordinaryTax + ltcgTax + recaptureTax + niit;

  // --- §4.3.4 --------------------------------------------------------------
  final qualifyingChildren =
      unit.qualifyingChildren(year, taxYear.childTaxCreditQualifyingAge);
  final earnedIncome =
      sumMoney(unitWages.map((w) => w.wageIncome + w.seNetEarnings));

  final over = (income.federalAgi -
          threshold(taxYear.childTaxCreditPhaseOutThreshold[status]!))
      .orZeroIfNegative;
  final steps = over.isZero
      ? 0
      : (over.cents / taxYear.childTaxCreditPhaseOutStep.cents).ceil();
  final ctcPhaseOut = taxYear.childTaxCreditPhaseOutPerThousand * steps;
  final ctcAfterPhaseOut =
      (taxYear.childTaxCreditPerChild * qualifyingChildren - ctcPhaseOut)
          .orZeroIfNegative;

  // The non-refundable portion cannot push federal tax below zero; beyond it
  // the refundable portion is capped per child and by earned income, so tax
  // goes negative only by that bounded amount (§4.3.4).
  final nonRefundableCtc =
      minMoney(ctcAfterPhaseOut, taxBeforeCredits.orZeroIfNegative);
  final refundableCtc = _minOf([
    ctcAfterPhaseOut - nonRefundableCtc,
    taxYear.childTaxCreditRefundablePerChild * qualifyingChildren,
    (earnedIncome -
                threshold(taxYear.childTaxCreditRefundableEarnedIncomeFloor))
            .orZeroIfNegative *
        taxYear.childTaxCreditRefundableRate,
  ]);
  final childTaxCredit = nonRefundableCtc + refundableCtc;

  // --- §4.3.5 --------------------------------------------------------------
  final health = computeHealthCredit(
    unit,
    household: household,
    income: income,
    assumptions: assumptions,
    taxYear: taxYear,
    year: year,
  );

  // --- §4.3.6 --------------------------------------------------------------
  final stateTax = _jurisdictionTax(
    taxYear.stateRules[unit.stateCode],
    income: income,
    status: unit.filingStatus,
    unitAccounts: household.accounts
        .where((a) => personIds.contains(a.personId))
        .toList(),
  );
  final localTax = unit.localityCode == null
      ? Money.zero
      : _jurisdictionTax(
          taxYear.localRules[unit.localityCode],
          income: income,
          status: unit.filingStatus,
          unitAccounts: household.accounts
              .where((a) => personIds.contains(a.personId))
              .toList(),
        );

  return TaxOwed(
    ordinaryPortion: ordinaryPortion,
    preferentialPortion: preferentialPortion,
    ordinaryTax: ordinaryTax,
    ltcgTax: ltcgTax,
    netInvestmentIncome: netInvestmentIncome,
    niit: niit,
    recaptureTax: recaptureTax,
    taxBeforeCredits: taxBeforeCredits,
    childTaxCredit: childTaxCredit,
    federalTax: taxBeforeCredits - childTaxCredit,
    stateTax: stateTax,
    localTax: localTax,
    payrollTax: sumMoney(unitWages.map((w) => w.payrollTax)),
    additionalMedicareTax: additionalMedicare(
      unitWages,
      taxYear: taxYear,
      status: status,
      year: year,
      currentYear: currentYear,
      inflation: inflation,
    ),
    withdrawalPenalty: penalties.penalty(taxYear),
    health: health,
  );
}

/// §4.3.5. What the marketplace charges this unit, and what the government pays
/// toward it.
HealthCredit computeHealthCredit(
  TaxUnit unit, {
  required Household household,
  required TaxableIncome income,
  required Assumptions assumptions,
  required TaxYear taxYear,
  required int year,
}) {
  final people = household.peopleIn(unit).toList();

  final acaMagi = income.federalAgi + (income.ssBenefits - income.taxableSS);
  final taxUnitSize = people.length + unit.activeDependents(year).length;
  final poverty = taxYear.povertyLevel(unit.stateCode, taxUnitSize);
  final fplPercent = poverty.isZero ? 0.0 : 100 * acaMagi.ratioTo(poverty);

  // Employer coverage suppresses both sides: a person still on a plan
  // generates no benchmark premium and no credit (§4.3.5).
  final covered = people.where((p) =>
      p.ageIn(year) < 65 &&
      year > (p.employerHealthCoverageEndYear ?? -1 << 31));

  // The fallback sums over nobody, but an entered override does not, so the
  // gate comes first (§4.3.5).
  final benchmarkPremium = covered.isEmpty
      ? Money.zero
      : unit.benchmarkPremiumOverride ??
          sumMoney(covered.map((p) =>
              taxYear.acaBenchmarkPremiumByAge[p.ageIn(year)] ?? Money.zero));

  final aboveFloor = fplPercent >= taxYear.acaMinimumFplPercent;
  final belowCeiling = taxYear.acaMaximumFplPercent == null ||
      fplPercent <= taxYear.acaMaximumFplPercent!;
  final eligible = covered.isNotEmpty && aboveFloor && belowCeiling;

  final applicablePercent =
      _interpolateApplicablePercent(taxYear.acaApplicablePercentageTable, fplPercent);
  final expectedContrib = acaMagi * applicablePercent;

  return HealthCredit(
    acaMagi: acaMagi,
    taxUnitSize: taxUnitSize,
    fplPercent: fplPercent,
    benchmarkPremium: benchmarkPremium,
    eligible: eligible,
    premiumTaxCredit: eligible
        ? (benchmarkPremium - expectedContrib).orZeroIfNegative
        : Money.zero,
    belowSubsidyFloor: covered.isNotEmpty && !aboveFloor,
  );
}

/// Linear interpolation between consecutive points, with two points sharing an
/// `fplPercent` expressing a step (§3.12).
Rate _interpolateApplicablePercent(
  List<ApplicablePercentagePoint> table,
  double fplPercent,
) {
  if (table.isEmpty) return 0;
  if (fplPercent <= table.first.fplPercent) return table.first.applicablePercent;
  if (fplPercent >= table.last.fplPercent) return table.last.applicablePercent;
  for (var i = 0; i < table.length - 1; i++) {
    final a = table[i];
    final b = table[i + 1];
    if (fplPercent >= a.fplPercent && fplPercent <= b.fplPercent) {
      if (b.fplPercent == a.fplPercent) return b.applicablePercent;
      final t = (fplPercent - a.fplPercent) / (b.fplPercent - a.fplPercent);
      return a.applicablePercent +
          t * (b.applicablePercent - a.applicablePercent);
    }
  }
  return table.last.applicablePercent;
}

/// A state or locality's own layer, following the federal shape (§4.3.6).
///
/// The conformity flag is what lets a state diverge on pre-tax deferrals: where
/// it does not conform, those contributions are added back before its schedule
/// runs.
Money _jurisdictionTax(
  JurisdictionRules? rules, {
  required TaxableIncome income,
  required List<Account> unitAccounts,
  required FilingStatus status,
}) {
  if (rules == null || rules.leviesNoIncomeTax) return Money.zero;

  var base = income.federalAgi;
  if (!rules.conformsToPreTaxDeferrals) {
    base += sumMoney(unitAccounts
        .where((a) => a.contribution.reducesStateTaxableIncome)
        .map((a) => Money(a.contribution.mode == ContributionMode.fixedAmount
            ? a.contribution.value.round()
            : 0)));
  }
  // An exclusion offsets retirement income and nothing else, so it is capped
  // by how much of that the unit actually received.
  final retirementIncome = income.pensionIncome + income.rmdIncome;
  final exclusion =
      _minOf([rules.retirementIncomeExclusionFor(status), retirementIncome]);

  final taxable = (base -
          rules.standardDeductionFor(status) -
          rules.personalExemptionFor(status) -
          exclusion)
      .orZeroIfNegative;

  final tax = rules.flatRate != null
      ? taxable * rules.flatRate!
      : applyBrackets(taxable, rules.bracketsFor(status));
  return (tax - rules.personalCreditFor(status)).orZeroIfNegative;
}

Money _minOf(List<Money> values) =>
    values.reduce((a, b) => a.cents <= b.cents ? a : b);
