/// §3.11. What a benefit is worth once claiming age is accounted for.
///
/// This runs **once**, at `claimingAge`, and §4.3.1 and §8.4 consume the result
/// rather than the statement figure. The benefit is already in real terms, so
/// no COLA is applied: §1.1 assumes COLA tracks inflation.
library;

import '../entities/person.dart';
import '../taxyear/tax_year.dart';
import '../types.dart';

/// The monthly benefit after the reduction for claiming early or the credit for
/// claiming late (§3.11).
Money adjustedMonthlyBenefit(
  SocialSecurityBenefit benefit, {
  required DateTime birthDate,
  required TaxYear taxYear,
}) {
  final fraMonths = taxYear.socialSecurityFraByBirthYear[birthDate.year] ??
      _nearestFra(taxYear, birthDate.year);
  final claimingMonths = benefit.claimingAge * 12;
  final monthsEarly =
      claimingMonths < fraMonths ? fraMonths - claimingMonths : 0;
  final monthsLate = claimingMonths > fraMonths ? claimingMonths - fraMonths : 0;

  final c = taxYear.claimingAdjustment;
  final firstTranche =
      monthsEarly < c.earlyFirstMonths ? monthsEarly : c.earlyFirstMonths;
  final beyond = monthsEarly > c.earlyFirstMonths
      ? monthsEarly - c.earlyFirstMonths
      : 0;

  final factor = 1 -
      firstTranche * c.earlyRate -
      beyond * c.earlyRateBeyond +
      monthsLate * c.delayedRate;

  return benefit.estimatedMonthlyBenefitAtFra * factor;
}

/// Birth years outside the published table take the nearest published row.
/// The table assumes 1943 or later; earlier years are outside the app's
/// audience and would otherwise divide by nothing.
int _nearestFra(TaxYear taxYear, int birthYear) {
  final years = taxYear.socialSecurityFraByBirthYear.keys.toList()..sort();
  if (years.isEmpty) return 67 * 12;
  final bounded = birthYear < years.first
      ? years.first
      : (birthYear > years.last ? years.last : years.first);
  return taxYear.socialSecurityFraByBirthYear[bounded]!;
}

/// Whether this person's benefit counts in [year] (§3.11, §4.3.1).
///
/// Both the scenario switch and the person's own flag must be true, so the
/// scenario answers "what if Social Security isn't there at all" and the person
/// answers "I count on mine but not my spouse's".
bool benefitCountsIn(
  Person person,
  int year, {
  required bool includeSocialSecurity,
}) {
  final ss = person.socialSecurity;
  if (ss == null || !includeSocialSecurity || !ss.includeInProjection) {
    return false;
  }
  return person.ageIn(year) >= ss.claimingAge;
}
