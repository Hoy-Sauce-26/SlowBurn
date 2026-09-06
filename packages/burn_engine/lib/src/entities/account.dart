import 'dart:math' as math;

import '../enums.dart';
import '../types.dart';
import 'spanned.dart';

/// §3.4.4. The employer's own contribution formula, embedded in a
/// [Contribution].
class EmployerMatch {
  final MatchFormula formula;
  final Rate matchRate;
  final Rate matchLimitPercentOfSalary;
  final List<MatchTier> tiers;

  /// Surfaced as `unvestedMatchAtRisk` and reducing no balance (§3.4.4).
  final VestingSchedule? vestingSchedule;

  const EmployerMatch({
    required this.formula,
    this.matchRate = 0,
    this.matchLimitPercentOfSalary = 0,
    this.tiers = const [],
    this.vestingSchedule,
  });

  /// §3.4.4. Employer dollars earned against [employeeContribution], given the
  /// pay behind this account's employer.
  ///
  /// Zero compensation yields zero match, which is the right answer for an
  /// account no employer sponsors.
  Money matchOn(Money employeeContribution, Money employerComp) {
    if (employerComp <= 0) return 0;
    final employeePct = employeeContribution / employerComp;
    switch (formula) {
      case MatchFormula.percentOfContribution:
        return matchRate *
            math.min(
              employeeContribution,
              matchLimitPercentOfSalary * employerComp,
            );
      case MatchFormula.percentOfSalary:
        // A limit of zero makes this a non-elective contribution, owed whether
        // or not the employee defers anything.
        return employeePct >= matchLimitPercentOfSalary
            ? matchRate * employerComp
            : 0;
      case MatchFormula.tiered:
        var total = 0.0;
        var previousCeiling = 0.0;
        for (final tier in tiers) {
          final slice = math.max(
            0.0,
            math.min(employeePct, tier.upToPercentOfSalary) - previousCeiling,
          );
          total += tier.matchRate * employerComp * slice;
          previousCeiling = tier.upToPercentOfSalary;
        }
        return total;
    }
  }
}

/// §3.4.1. The committed flow into an account: the deferral or transfer the
/// user has actually set up, subtracted before any surplus exists.
class Contribution with Spanned {
  final ContributionMode mode;

  /// A decimal rate under [ContributionMode.percentOfGross], dollars under
  /// [ContributionMode.fixedAmount] (invariant 23).
  final double value;

  /// Which of the person's streams the percentage applies to. Required when
  /// [mode] is percentOfGross (invariant 8).
  final List<Id> contributionBaseStreamIds;

  final EmployerMatch? employerMatch;

  final bool reducesFederalTaxableIncome;
  final bool reducesStateTaxableIncome;
  final bool reducesFicaWages;

  @override
  final int? startYear;
  @override
  final int? endYear;
  @override
  final int? startMonth;
  @override
  final int? endMonth;

  const Contribution({
    required this.mode,
    required this.value,
    this.contributionBaseStreamIds = const [],
    this.employerMatch,
    this.reducesFederalTaxableIncome = false,
    this.reducesStateTaxableIncome = false,
    this.reducesFicaWages = false,
    this.startYear,
    this.endYear,
    this.startMonth,
    this.endMonth,
  });

  /// The uncapped dollars this contribution asks for in [year] (§3.4).
  ///
  /// A `percentOfGross` contribution needs no proration of its own: [base] is
  /// already the streams' resolved amounts, which carry the partial year.
  Money uncappedAmount(int year, {required Money base}) {
    if (!activeIn(year)) return 0;
    return switch (mode) {
      ContributionMode.fixedAmount => value * activeFraction(year),
      ContributionMode.percentOfGross => value * base,
    };
  }
}

/// §3.4. A balance plus the contribution that feeds it.
class Account {
  final Id id;
  final Id personId;
  final String label;
  final AccountKind kind;

  /// Stored alongside [kind] rather than derived at read time, so a custom
  /// account can set them. Invariant 29 keeps the pair sane.
  final TaxTreatment taxTreatment;
  final LimitFamily limitFamily;

  final Money balance;

  /// Required for `taxable`. Entered once, then maintained every projected
  /// year (§6.3).
  final Money costBasis;

  /// Withdrawable before 59½ without tax or penalty, from `rothIra` only
  /// (§8.4.1). Also engine state after entry.
  final Money rothContributionBasis;

  /// Starts the five-year clock (§8.4.1).
  final int? rothFirstContributionYear;

  final Contribution contribution;

  /// Which `Employer` sponsors the plan, shared with that person's streams.
  /// Null for IRAs and taxable accounts.
  final Id? employerId;

  final AllocationMode allocationMode;
  final Id? assetAllocationId;
  final List<AllocationWeight> allocationWeights;

  /// Derived from [taxTreatment], not from [kind] (§3.4).
  final bool isRestrictedPurpose;

  /// Only meaningful for the household's cash-buffer accounts (§4.5).
  final double? targetBalanceMonths;

  const Account({
    required this.id,
    required this.personId,
    required this.label,
    required this.kind,
    required this.taxTreatment,
    required this.limitFamily,
    required this.balance,
    this.costBasis = 0,
    this.rothContributionBasis = 0,
    this.rothFirstContributionYear,
    required this.contribution,
    this.employerId,
    this.allocationMode = AllocationMode.singleClass,
    this.assetAllocationId,
    this.allocationWeights = const [],
    required this.isRestrictedPurpose,
    this.targetBalanceMonths,
  });
}
