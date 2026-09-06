import 'dart:math' as math;

import '../enums.dart';
import '../types.dart';
import 'spanned.dart';

/// §3.7. A meta-category grouping related sub-category items.
class ExpenseCategory {
  final Id id;
  final Id householdId;
  final String label;
  final MetaCategory metaCategory;

  /// Non-null, defaulting to 0, which is what terminates the fallback below.
  final Rate defaultRelativeInflation;

  const ExpenseCategory({
    required this.id,
    required this.householdId,
    required this.label,
    required this.metaCategory,
    this.defaultRelativeInflation = 0,
  });
}

/// §3.7. One spending line, inflating at its own real rate relative to general
/// inflation.
class ExpenseItem with Spanned {
  final Id id;
  final Id categoryId;
  final String label;

  /// Normalised to annual on save.
  final Money amount;
  final ExpenseFrequency frequency;

  @override
  final int? startYear;
  @override
  final int? endYear;
  @override
  final int? startMonth;
  @override
  final int? endMonth;

  /// Real, relative to general inflation. Null inherits the category's default,
  /// which is the whole point of that field; a stored 0 is a deliberate flat
  /// rate and overrides it.
  final Rate? relativeInflationRate;

  final ExpensePhase phase;

  /// For `both` items whose amount changes at retirement.
  final Money? postRetirementAmount;

  const ExpenseItem({
    required this.id,
    required this.categoryId,
    required this.label,
    required this.amount,
    this.frequency = ExpenseFrequency.annual,
    this.startYear,
    this.endYear,
    this.startMonth,
    this.endMonth,
    this.relativeInflationRate,
    this.phase = ExpensePhase.both,
    this.postRetirementAmount,
  });

  /// Whether this line is spent in [year], given the household's retirement
  /// year (§3.7). The boundary is the household's, never per person.
  bool appliesIn(int year, {required int? retirementYear}) {
    if (!activeIn(year)) return false;
    if (retirementYear == null) return phase != ExpensePhase.postRetirementOnly;
    final retired = year >= retirementYear;
    return switch (phase) {
      ExpensePhase.preRetirementOnly => !retired,
      ExpensePhase.postRetirementOnly => retired,
      ExpensePhase.both => true,
    };
  }

  /// This line's cost in [year] (§3.7).
  ///
  /// Relative inflation compounds from the base year; nothing else about an
  /// expense does. A zero rate leaves the amount flat in real terms, which is
  /// what §1.1 means by holding today's dollars.
  Money amountIn(
    int year, {
    required int currentYear,
    required int? retirementYear,
    required Rate categoryDefaultInflation,
  }) {
    if (!appliesIn(year, retirementYear: retirementYear)) return 0;
    final rate = relativeInflationRate ?? categoryDefaultInflation;
    final retired = retirementYear != null && year >= retirementYear;
    final base =
        retired && postRetirementAmount != null ? postRetirementAmount! : amount;
    return base *
        math.pow(1 + rate, year - currentYear) *
        activeFraction(year);
  }
}
