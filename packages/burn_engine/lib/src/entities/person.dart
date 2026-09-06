import '../types.dart';

/// §3.11. A benefit the user reads off their SSA statement, adjusted once for
/// claiming age and never recomputed.
class SocialSecurityBenefit {
  final Id personId;
  final Money estimatedMonthlyBenefitAtFra;

  /// 62–70 whole years, per invariant 27.
  final int claimingAge;

  /// Whether this person's benefit counts. Both this and the scenario-level
  /// `includeSocialSecurity` must be true (§3.9).
  final bool includeInProjection;

  const SocialSecurityBenefit({
    required this.personId,
    required this.estimatedMonthlyBenefitAtFra,
    required this.claimingAge,
    this.includeInProjection = true,
  });
}

/// §3.1. The unit that FICA caps, contribution limits, and age-gated account
/// access apply to.
class Person {
  final Id id;
  final String displayName;
  final DateTime birthDate;
  final Id taxUnitId;

  /// Fixes this person's retirement year rather than leaving §8.2 to solve for
  /// it. Null is the common case.
  final int? plannedRetirementAge;

  final List<HsaCoverageEntry> hsaCoverage;

  /// Defaults to the year before their retirement year (§3.1). Null means the
  /// default applies; the engine resolves it once the retirement year is known.
  final int? employerHealthCoverageEndYear;

  final SocialSecurityBenefit? socialSecurity;

  const Person({
    required this.id,
    required this.displayName,
    required this.birthDate,
    required this.taxUnitId,
    this.plannedRetirementAge,
    this.hsaCoverage = const [],
    this.employerHealthCoverageEndYear,
    this.socialSecurity,
  });

  /// The age *attained during* [year] (§3.1), which is what statute uses for
  /// catch-up eligibility, RMD age, and Social Security claiming.
  int ageIn(int year) => year - birthDate.year;

  /// The coverage tier in force for [year], from the ordered timeline. Entries
  /// run from their `fromYear` until the next one starts.
  HsaTier hsaTierIn(int year) {
    var tier = HsaTier.none;
    for (final entry in hsaCoverage) {
      if (entry.fromYear <= year) {
        tier = entry.tier;
      } else {
        break;
      }
    }
    return tier;
  }

  /// Whether this person can reach tax-deferred money without the 10% penalty
  /// in [year] (§3.1).
  ///
  /// **Rounded conservatively**: eligible only if `birthDate + 59 years
  /// 6 months` falls on or before January 1 of that year. At annual
  /// granularity the alternative grants a full year of penalty-free access to
  /// someone who turns 59½ in December, and erring toward the penalty is the
  /// safe direction for a test that gates a retirement date.
  ///
  /// So it is not simply "age 60": a July birthday reaches it a year later
  /// than a January one.
  bool isPenaltyFreeIn(int year) {
    final threshold = DateTime(
      birthDate.year + 59,
      birthDate.month + 6,
      birthDate.day,
    );
    return !threshold.isAfter(DateTime(year, 1, 1));
  }

  /// Their retirement year where they fixed one, otherwise null so the caller
  /// falls back to the household's solved year (§3.1).
  int? get plannedRetirementYear =>
      plannedRetirementAge == null ? null : birthDate.year + plannedRetirementAge!;
}
