import 'dart:math' as math;

import 'package:burn_engine/burn_engine.dart';

/// Education spending, gathered by the child it is for (§3.7).
class EducationPlan {
  /// Null for spending not tied to anybody.
  final Dependent? child;
  final List<ExpenseItem> items;

  const EducationPlan({this.child, required this.items});

  /// A line with no start year is already being paid.
  int firstYear(int thisYear) =>
      items.map((i) => i.startYear ?? thisYear).reduce(math.min);

  /// The first year anything can go in for this child: this year, or the
  /// year they are born, since a 529 is opened in a child's name.
  int savingFrom(int thisYear) =>
      math.max(thisYear, child?.birthDate.year ?? thisYear);

  /// Null while some of it has no end.
  int? get lastYear => items.any((i) => i.endYear == null)
      ? null
      : items.map((i) => i.endYear!).reduce(math.max);
}

/// Every child with education spending, in birth order, then whatever is tied
/// to nobody.
List<EducationPlan> educationByChild(Household household) {
  final meta = {
    for (final c in household.expenseCategories) c.id: c.metaCategory
  };
  final education = household.expenseItems
      .where((i) => meta[i.categoryId] == MetaCategory.education)
      .toList();
  final children = household.dependents.toList()
    ..sort((a, b) => a.birthDate.compareTo(b.birthDate));
  return [
    for (final child in children)
      if (education.any((i) => i.dependentId == child.id))
        EducationPlan(
          child: child,
          items: education.where((i) => i.dependentId == child.id).toList(),
        ),
    if (education.any((i) => i.dependentId == null))
      EducationPlan(
          items: education.where((i) => i.dependentId == null).toList()),
  ];
}

/// The 529 already saving for [child], or for nobody in particular.
Account? collegeAccountFor(Household household, Dependent? child) => household
    .accounts
    .where((a) => a.isRestrictedPurpose && a.beneficiaryId == child?.id)
    .firstOrNull;

/// What a child is called on screen: their name, or when they arrive.
String childName(Dependent child, {int? thisYear}) {
  if (child.name != null && child.name!.trim().isNotEmpty) {
    return child.name!.trim();
  }
  final year = child.birthDate.year;
  return year > (thisYear ?? DateTime.now().year)
      ? 'Planned for $year'
      : 'Born $year';
}

/// The level yearly deposit that pays for all of [plan] from a 529, put in
/// from [EducationPlan.savingFrom] until the year before the first bill
/// (§3.4).
///
/// In today's money, like every figure in the plan. [growth] is what the
/// account earns while it waits and [drawdown] what it earns once the bills
/// start, since it moves somewhere safer then. Null where the bills start
/// before saving can, which leaves no years to save in.
Money? fullFundingDeposit(
  Household household,
  EducationPlan plan, {
  required Money balance,
  required Rate growth,
  required Rate drawdown,
  required int thisYear,
}) {
  final first = plan.firstYear(thisYear);
  final start = plan.savingFrom(thisYear);
  if (first <= start) return null;
  final last = plan.lastYear ?? thisYear + 60;

  final categories = {for (final c in household.expenseCategories) c.id: c};
  var needed = 0.0;
  for (var year = first; year <= last; year++) {
    final cost = sumMoney(plan.items.map((i) => i.amountIn(
          year,
          currentYear: thisYear,
          retirementYear: null,
          categoryDefaultInflation:
              categories[i.categoryId]?.defaultRelativeInflation ?? 0,
        )));
    needed += cost.dollars / math.pow(1 + drawdown, year - first);
  }

  final alreadyThere =
      balance.dollars * math.pow(1 + growth, first - thisYear);
  var perDollar = 0.0;
  for (var year = start; year < first; year++) {
    perDollar += math.pow(1 + growth, first - year);
  }
  // Whole dollars: it is an estimate, and it is what somebody would type.
  return Money.dollars(
      (math.max(0, needed - alreadyThere) / perDollar).roundToDouble());
}

/// The plan as it stands with [account] paid into, beside the same plan with
/// nothing more going in. Whatever would have gone into it goes wherever the
/// rest of the year's savings go instead.
({Band<BandResult> saving, Band<BandResult> notSaving}) compareSaving(
  Household household,
  Account account, {
  required Assumptions assumptions,
  required TaxYear taxYear,
  required Map<Id, AssetClass> assetClasses,
  required DateTime asOfDate,
}) {
  Household withAccount(Account a) => household.copyWith(accounts: [
        for (final other in household.accounts)
          if (other.id != a.id) other,
        a,
      ]);
  Band<BandResult> solve(Household h) => solveAllBands(h,
      assumptions: assumptions,
      taxYear: taxYear,
      assetClasses: assetClasses,
      asOfDate: asOfDate);

  return (
    saving: solve(withAccount(account)),
    notSaving: solve(withAccount(account.withContribution(
        const Contribution(mode: ContributionMode.fixedAmount, value: 0)))),
  );
}

/// Every dollar of tax a projection pays, federal, state and payroll alike.
Money taxOver(Projection projection) => sumMoney(projection.years
    .map((y) => y.solved.cashFlow.totalTaxOwed * y.frac));
