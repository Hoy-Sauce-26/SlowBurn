import 'dart:math' as math;

import '../enums.dart';
import '../types.dart';
import 'spanned.dart';

/// §3.3. A label two entities can point at, so an `IncomeStream` and an
/// `Account` can be checked for naming the same one (invariant 25).
class Employer {
  final Id id;
  final Id householdId;
  final String label;

  const Employer({
    required this.id,
    required this.householdId,
    required this.label,
  });
}

/// §3.3. One earning source, active across a span and growing at its own real
/// rate.
class IncomeStream with Spanned {
  final Id id;
  final Id personId;
  final Id? employerId;
  final String label;
  final IncomeKind kind;

  /// The **full-year** rate. What a partial year pays is [resolvedAmount].
  final Money grossAnnualAmount;

  final Rate realGrowthRate;

  @override
  final int? startYear;
  @override
  final int? endYear;
  @override
  final int? startMonth;
  @override
  final int? endMonth;

  final bool isFicaSubject;
  final bool isQualifiedBusinessIncome;
  final bool isSpecifiedServiceBusiness;

  /// Display only, read by no engine calculation (§3.3).
  final IncomeVariability variability;

  const IncomeStream({
    required this.id,
    required this.personId,
    required this.label,
    required this.kind,
    required this.grossAnnualAmount,
    this.realGrowthRate = 0,
    this.employerId,
    this.startYear,
    this.endYear,
    this.startMonth,
    this.endMonth,
    required this.isFicaSubject,
    required this.isQualifiedBusinessIncome,
    this.isSpecifiedServiceBusiness = false,
    this.variability = IncomeVariability.guaranteed,
  });

  /// What this stream actually pays in [year] (§3.3).
  ///
  /// Growth compounds on the full-year rate, and the partial year is taken
  /// afterwards. Every §4 sum over streams means this.
  ///
  /// A stream with no [startYear] is already running, so its entered amount is
  /// this year\'s figure and growth compounds from [currentYear]. Compounding
  /// from year zero instead would leave every existing salary flat forever.
  Money resolvedAmount(int year, {required int currentYear}) {
    if (!activeIn(year)) return Money.zero;
    final growth =
        math.pow(1 + realGrowthRate, year - (startYear ?? currentYear));
    return grossAnnualAmount * (growth * activeFraction(year));
  }
}
