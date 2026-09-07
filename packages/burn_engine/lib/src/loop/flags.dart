/// The `flags[]` a projected year carries (§6).
///
/// A flag is how the engine says its answer has a caveat. Anything that can
/// fail quietly gets a way to be seen: a number that is wrong for a reason the
/// model already knows about should never arrive silently.
library;

import '../entities/assumptions.dart';
import '../entities/household.dart';
import '../enums.dart';
import '../pipeline/federal_tax.dart';
import '../pipeline/income_tax.dart';
import '../pipeline/limits.dart';
import '../pipeline/social_security.dart';
import '../pipeline/wages.dart';
import '../taxyear/tax_year.dart';
import '../types.dart';
import 'amortization.dart';
import 'housing.dart';

/// Every flag the loop can raise from one year's own figures.
///
/// Three it cannot: `magiCeilingBreached` needs §8.4.4's subsidy-aware
/// ordering, and `bridgeGapDetected` and `retirementSpendingNotLevel` belong to
/// §8.2's candidate evaluation and are raised there.
Set<String> yearFlags({
  required Household household,
  required Assumptions assumptions,
  required TaxYear taxYear,
  required List<PersonWages> wages,
  required List<TaxableIncome> incomes,
  required List<TaxOwed> owed,
  required List<ResolvedContribution> contributions,
  required Map<Id, LiabilityState> liabilities,
  required DateTime asOfDate,
  required int year,

  /// Null until §8.2 has solved one. What it changes here is whether a
  /// phase-limited housing cost reaches this year.
  int? retirementYear,
}) {
  final flags = <String>{};

  for (final o in owed) {
    // The real program pays nothing below the floor, and the household's
    // options there are a decision, so this is said rather than silently
    // zeroed (§4.3.5).
    if (o.health.belowSubsidyFloor) flags.add('acaMagiBelowSubsidyFloor');
  }

  for (var i = 0; i < household.taxUnits.length; i++) {
    final unit = household.taxUnits[i];
    final income = incomes[i];

    // A unit filing headOfHousehold in a year with no active dependent is
    // computed as single for that year, and said so (invariant 23).
    if (unit.filingStatus == FilingStatus.headOfHousehold &&
        unit.activeDependents(year).isEmpty) {
      flags.add('filingStatusNoLongerQualifies');
    }

    // Above the threshold the engine applies the unlimited 20%, which
    // overstates the deduction for exactly the high-earning professional the
    // real limits target (§4.3.2).
    final threshold = taxYear.qbiThreshold[unit.filingStatus];
    if (income.qbiDeduction.isPositive &&
        threshold != null &&
        income.federalAgi > threshold.value) {
      flags.add('qbiLimitNotModeled');
    }
  }

  for (final person in household.people) {
    // Medicare enrolment ends HSA eligibility (§3.4.2).
    final fundsHsa = contributions.any((c) {
      final account = household.accountById(c.accountId);
      return account?.personId == person.id &&
          account?.limitFamily == LimitFamily.hsa &&
          c.employee.isPositive;
    });
    if (person.ageIn(year) >= 65 && fundsHsa) {
      flags.add('hsaContributionsStoppedAtMedicare');
    }

    // Claiming before full retirement age while still earning: the real
    // program would withhold part of the benefit and the engine pays it in
    // full (§3.11, §13.3).
    final ss = person.socialSecurity;
    if (ss != null &&
        benefitCountsIn(person, year,
            includeSocialSecurity: assumptions.includeSocialSecurity)) {
      final fraMonths =
          taxYear.socialSecurityFraByBirthYear[person.birthDate.year];
      final earning = wages
          .where((w) => w.personId == person.id)
          .any((w) => (w.wageIncome + w.seEarnings).isPositive);
      if (fraMonths != null && ss.claimingAge * 12 < fraMonths && earning) {
        flags.add('earningsTestNotModeled');
      }
    }
  }

  for (final c in contributions) {
    final account = household.accountById(c.accountId);
    if (account == null) continue;

    // Surfaced as a warning, reducing no balance (§3.4.4).
    final vesting = account.contribution.employerMatch?.vestingSchedule;
    if (c.employerMatch.isPositive && matchAtRisk(vesting)) {
      flags.add('unvestedMatchAtRisk');
    }

    // The backdoor route that would make it legal is a conversion the engine
    // cannot yet model (§4.4.4).
    if (account.kind == AccountKind.rothIra && c.uncapped.isPositive) {
      final person = household.personById(account.personId);
      final unit =
          person == null ? null : household.taxUnitById(person.taxUnitId);
      if (unit != null) {
        final limit = taxYear.rothIraIncomeLimit[unit.filingStatus];
        final index = household.taxUnits.indexOf(unit);
        if (limit != null && index >= 0 && index < incomes.length) {
          if (incomes[index].preDeductionMagi >= limit.upper) {
            flags.add('rothIraIncomeLimitReached');
          }
        }
      }
    }
  }

  for (final debt in liabilities.values) {
    if (debt.escrowDiffersFromInferred(asOfDate: asOfDate)) {
      flags.add('escrowDiffersFromInferred');
    }
    // The escrow account ends at payoff; the obligations inside it do not
    // (§3.6).
    if (debt.paidOff &&
        debt.liability.escrowContinuesAfterPayoff > 0 &&
        debt.escrowPaidThisYear.isPositive) {
      flags.add('payoffLeavesResidualEscrow');
    }
    if (_derivedPayoffDiffersFromTerm(debt, asOfDate)) {
      flags.add('derivedPayoffDiffersFromTerm');
    }
  }

  // Everybody lives somewhere. A year in which the household holds no home
  // and pays nothing for housing is being projected as though shelter were
  // free, which is the largest thing a plan can lose by omission rather than
  // by choice: selling a house is one field, and nothing else notices (§3.7).
  if (coversIn(household, year, retirementYear: retirementYear).isEmpty) {
    flags.add('noHousingCost');
  }

  return flags;
}

/// §3.6. Whether the payoff the balance and payment imply disagrees materially
/// with the entered term, in which case the derived figure is kept and this is
/// said.
bool _derivedPayoffDiffersFromTerm(LiabilityState debt, DateTime asOfDate) {
  final l = debt.liability;
  if (!l.currentBalance.isPositive || !l.monthlyPayment.isPositive) {
    return false;
  }
  final escrow = debt.monthlyEscrow(asOfDate: asOfDate);
  final pandi = (l.monthlyPayment - escrow).orZeroIfNegative;
  if (!pandi.isPositive) return false;

  final monthlyRate = l.interestRate / 12;
  var balance = l.currentBalance;
  var months = 0;
  while (balance.isPositive && months < 1200) {
    final interest = balance * monthlyRate;
    final principal = pandi - interest;
    if (!principal.isPositive) return false;
    balance -= minMoney(principal, balance);
    months++;
  }

  final elapsed = (asOfDate.year - l.originationDate.year) * 12 +
      (asOfDate.month - l.originationDate.month);
  final remainingTerm = l.termMonths - (elapsed < 0 ? 0 : elapsed);
  return (months - remainingTerm).abs() > 12;
}

/// Invariant 16's warn-and-flag check: an `ExpenseItem` that looks like it
/// restates something already carried into `netSurplus` by its own term.
///
/// A judgement rather than a proof, which is why it warns instead of blocking.
Set<String> doubleCountFlags(Household household) {
  final flags = <String>{};
  final categories = {for (final c in household.expenseCategories) c.id: c};
  for (final item in household.expenseItems) {
    final meta = categories[item.categoryId]?.metaCategory;
    final label = item.label.toLowerCase();
    final looksLikeDebt = label.contains('mortgage') ||
        label.contains('loan payment') ||
        household.liabilities.any((l) =>
            l.label.isNotEmpty && label.contains(l.label.toLowerCase()));
    final looksLikePremium = meta == MetaCategory.health &&
        (label.contains('premium') || label.contains('insurance'));
    if (looksLikeDebt || looksLikePremium) flags.add('possibleDoubleCount');
  }
  return flags;
}

/// §8.1. The rate a retirement of this length is usually planned on.
///
/// The 4% rule is an empirical finding about a **thirty-year** retirement, and
/// it is quoted far more often than its horizon is. Someone stopping at 45 has
/// to fund fifty years, where the same rate runs out. The ladder is coarse on
/// purpose: the underlying studies disagree in the second decimal place, and a
/// number carried to four would be claiming precision nobody has.
///
/// Not derivable from the projection's own arithmetic. The deterministic rate
/// that empties a portfolio over N years at return r is simply 1/annuity, and
/// at 5% real over 30 years that is 6.2%. The gap between that and 4% is the
/// price of the order returns arrive in, which the bands cannot express
/// (§13.1). This ladder carries the empirical answer instead.
Rate suggestedWithdrawalRate(int retirementDurationYears) {
  if (retirementDurationYears >= 45) return 0.035;
  if (retirementDurationYears >= 35) return 0.040;
  if (retirementDurationYears >= 25) return 0.045;
  return 0.050;
}

/// Whether the withdrawal rate suits the horizon it has to survive: a longer
/// retirement needs a lower rate, and the difference is not marginal.
///
/// Reads the same ladder the suggestion offers, so the app cannot recommend a
/// rate and then flag it.
bool swrHorizonMismatch(Assumptions assumptions, int retirementDurationYears) =>
    assumptions.safeWithdrawalRate >
        suggestedWithdrawalRate(retirementDurationYears);

/// The vesting schedules that put a match at risk (§3.4.4).
bool matchAtRisk(VestingSchedule? schedule) =>
    schedule != null && schedule is! ImmediateVesting;
