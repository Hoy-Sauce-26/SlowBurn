/// §3.7. Where the household lives, year by year, for the whole projection.
///
/// A plan is a sequence of homes, and the gaps between them are what nobody
/// notices: a house sold in 2046 leaves fourteen years of free accommodation
/// unless something else is entered for them. Checking one year at a time
/// answers "am I housed now", which is the wrong question. This answers "am I
/// housed for the whole of it", which is the one that catches the sale.
library;

import '../entities/expenses.dart';
import '../entities/household.dart';
import '../enums.dart';
import '../types.dart';

/// One unbroken stretch of living somewhere, or of living nowhere.
class HousingSpan {
  final int fromYear;
  final int toYear;

  /// What covers it. Empty where nothing does, which is the whole point.
  final List<HousingCover> covers;

  const HousingSpan({
    required this.fromYear,
    required this.toYear,
    required this.covers,
  });

  bool get isGap => covers.isEmpty;
  int get years => toYear - fromYear + 1;
}

/// A home owned or a housing cost paid, whichever is holding a span up.
class HousingCover {
  final Id id;
  final String label;
  final bool owned;

  const HousingCover({
    required this.id,
    required this.label,
    required this.owned,
  });
}

/// The whole run, collapsed into spans that share the same cover.
///
/// [retirementYear] decides whether a phase-limited expense reaches a year;
/// null gives the household the benefit of the doubt, as §6 does before §8.2
/// has solved one.
List<HousingSpan> housingTimeline(
  Household household, {
  required int fromYear,
  required int toYear,
  int? retirementYear,
}) {
  final spans = <HousingSpan>[];
  for (var year = fromYear; year <= toYear; year++) {
    final covers = coversIn(household, year, retirementYear: retirementYear);
    final key = covers.map((c) => c.id).join('|');
    if (spans.isNotEmpty &&
        spans.last.covers.map((c) => c.id).join('|') == key) {
      spans[spans.length - 1] = HousingSpan(
        fromYear: spans.last.fromYear,
        toYear: year,
        covers: spans.last.covers,
      );
    } else {
      spans.add(HousingSpan(fromYear: year, toYear: year, covers: covers));
    }
  }
  return spans;
}

/// Whether the household has somewhere to live in [year]. The question the
/// per-year flag asks; [housingTimeline] is the one a person needs answered.
bool housedIn(Household household, int year, {int? retirementYear}) =>
    coversIn(household, year, retirementYear: retirementYear).isNotEmpty;

/// Everything housing the household in one year.
List<HousingCover> coversIn(
  Household household,
  int year, {
  int? retirementYear,
}) {
  final covers = <HousingCover>[];
  for (final asset in household.assets) {
    if (asset.category == AssetCategory.primaryResidence &&
        asset.heldIn(year)) {
      covers.add(
          HousingCover(id: asset.id, label: asset.label, owned: true));
    }
  }
  final housing = household.expenseCategories
      .where((c) => c.metaCategory == MetaCategory.housing)
      .map((c) => c.id)
      .toSet();
  for (final item in household.expenseItems) {
    if (housing.contains(item.categoryId) &&
        item.amount.isPositive &&
        item.activeIn(year) &&
        phaseCovers(item.phase, year, retirementYear)) {
      covers.add(HousingCover(id: item.id, label: item.label, owned: false));
    }
  }
  return covers;
}

/// Whether an item's phase reaches [year]. Unknowable before a retirement year
/// is solved, and the benefit of the doubt goes to the household there.
bool phaseCovers(ExpensePhase phase, int year, int? retirementYear) {
  if (retirementYear == null) return true;
  return switch (phase) {
    ExpensePhase.both => true,
    ExpensePhase.preRetirementOnly => year < retirementYear,
    ExpensePhase.postRetirementOnly => year >= retirementYear,
  };
}

/// Whether a housing cost's home is standing in [year].
///
/// An item naming no home is on its own dates. One naming a home it cannot
/// find is treated the same way, since dropping a cost because a reference
/// went stale would quietly shrink somebody's spending.
bool housingCostStandsIn(
  Household household,
  ExpenseItem item,
  int year, {
  int? retirementYear,
}) {
  final home = item.housingId;
  if (home == null) return true;

  final asset = household.assets.where((a) => a.id == home).firstOrNull;
  if (asset != null) return asset.heldIn(year);

  final rent = household.expenseItems.where((i) => i.id == home).firstOrNull;
  if (rent != null) {
    return rent.activeIn(year) &&
        phaseCovers(rent.phase, year, retirementYear);
  }
  return true;
}
