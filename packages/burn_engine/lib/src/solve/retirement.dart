/// §8.2. The retirement test, and the search for the first year that passes it.
///
/// A year qualifies when all three legs hold: the portfolio clears the FIRE
/// number after embedded tax, the bridge is funded, and the decumulation
/// simulation survives to `projectionHorizonAge`. Leg 3 is a full multi-decade
/// simulation, so legs 1 and 2 gate it.
library;

import '../entities/assumptions.dart';
import '../entities/household.dart';
import '../enums.dart';
import '../loop/account_state.dart';
import '../loop/projection.dart';
import '../taxyear/tax_year.dart';
import '../types.dart';
import 'bridge.dart';
import 'fire_number.dart';

/// What one candidate year was tested against, and why it passed or did not.
class CandidateYear {
  final int year;
  final Money afterTaxLiquidNetWorth;
  final FireNumber fire;
  final BridgeCheck bridge;

  final bool clearsFireNumber;
  final bool survivesHorizon;

  const CandidateYear({
    required this.year,
    required this.afterTaxLiquidNetWorth,
    required this.fire,
    required this.bridge,
    required this.clearsFireNumber,
    required this.survivesHorizon,
  });

  bool get qualifies =>
      clearsFireNumber && !bridge.bridgeGapDetected && survivesHorizon;
}

/// One band's answer.
class BandResult {
  final BandName band;

  /// The first qualifying year, or null where none qualified within the
  /// horizon: `notReachable`, never a blank and never an arbitrarily distant
  /// year (§8.2).
  final Reachable<int> retirementYear;

  final Reachable<Money> fireNumber;

  /// What retirement costs, as §8.1 sizes it: the flat annual amount worth the
  /// same as the whole projected stream.
  ///
  /// The demand side, and not to be confused with [sustainableLevelSpending],
  /// which is the supply side. They meet at the solved year by construction
  /// and answer opposite questions: this one moves when spending changes, that
  /// one moves when the pot does.
  final Reachable<Money> levelEquivalentRetirementExpenses;

  /// What the first retired year costs, which is the figure a person
  /// recognises even though the level equivalent is what sizes the plan.
  final Reachable<Money> retirementAnnualExpenses;

  final Reachable<Money> sustainableLevelSpending;
  final Reachable<Money> spendingHeadroom;

  /// Where nothing qualified: net worth at the horizon against the FIRE number
  /// of the last candidate evaluated.
  final Money? shortfall;

  final List<CandidateYear> candidates;
  final Projection finalPass;

  const BandResult({
    required this.band,
    required this.retirementYear,
    required this.fireNumber,
    required this.levelEquivalentRetirementExpenses,
    required this.retirementAnnualExpenses,
    required this.sustainableLevelSpending,
    required this.spendingHeadroom,
    required this.shortfall,
    required this.candidates,
    required this.finalPass,
  });
}

/// §8.2 and §6.1, for one band.
///
/// The loop runs at two levels: a **baseline pass** in which everybody keeps
/// working, giving the balances each candidate year is read from, and a
/// **final pass** once the year is fixed, which is the projection the UI shows.
BandResult solveRetirement(
  Household household, {
  required Assumptions assumptions,
  required TaxYear taxYear,
  required Map<Id, AssetClass> assetClasses,
  required DateTime asOfDate,
  BandName band = BandName.expected,
}) {
  // A person with plannedRetirementAge set is not part of the circularity at
  // all: their year is known up front (§6.1).
  final fixed = household.people
      .map((p) => p.plannedRetirementYear)
      .whereType<int>()
      .toList();
  final fixedYear = fixed.isEmpty
      ? null
      : fixed.reduce((a, b) => a < b ? a : b);

  // Baseline pass: everybody keeps working, so every candidate year reads real
  // balances rather than balances that assumed the answer.
  final baseline = project(
    household,
    assumptions: assumptions,
    taxYear: taxYear,
    assetClasses: assetClasses,
    asOfDate: asOfDate,
    retirementYear: fixedYear,
    band: band,
  );

  final candidates = <CandidateYear>[];
  int? solved = fixedYear;

  if (fixedYear == null) {
    for (final projected in baseline.years) {
      final candidate = _evaluate(
        projected.year,
        household: household,
        assumptions: assumptions,
        taxYear: taxYear,
        assetClasses: assetClasses,
        asOfDate: asOfDate,
        band: band,
        baseline: baseline,
      );
      candidates.add(candidate);
      if (candidate.qualifies) {
        solved = candidate.year;
        break;
      }
    }
  }

  // Final pass, once the year is fixed: the emitted years describe a household
  // that actually stops working. The baseline was scaffolding.
  final finalPass = project(
    household,
    assumptions: assumptions,
    taxYear: taxYear,
    assetClasses: assetClasses,
    asOfDate: asOfDate,
    retirementYear: solved,
    band: band,
  );

  if (solved == null) {
    final last = baseline.years.last;
    final lastCandidate = candidates.isEmpty ? null : candidates.last;
    return BandResult(
      band: band,
      retirementYear: null,
      fireNumber: null,
      levelEquivalentRetirementExpenses: null,
      retirementAnnualExpenses: null,
      sustainableLevelSpending: null,
      spendingHeadroom: null,
      shortfall: lastCandidate == null
          ? null
          : lastCandidate.fire.fireNumber -
              last.netWorth.afterTaxLiquidNetWorth,
      candidates: candidates,
      finalPass: finalPass,
    );
  }

  final atRetirement = finalPass.yearOf(solved) ?? finalPass.years.last;
  // The two §8.2 raises, which belong to the candidate evaluation rather than
  // to a year's own figures.
  final chosen = candidates.where((c) => c.year == solved).firstOrNull;
  if (chosen?.bridge.bridgeGapDetected ?? false) {
    atRetirement.flags.add('bridgeGapDetected');
  }
  final fire = _fireNumberAt(
    solved,
    projection: finalPass,
    assumptions: assumptions,
    household: household,
  );

  // §9.4's inverse: what the plan as entered will actually support.
  final sustainable =
      atRetirement.netWorth.afterTaxLiquidNetWorth *
          assumptions.safeWithdrawalRate;

  if (fire.retirementSpendingNotLevel) {
    atRetirement.flags.add('retirementSpendingNotLevel');
  }

  return BandResult(
    band: band,
    retirementYear: solved,
    fireNumber: fire.fireNumber,
    levelEquivalentRetirementExpenses: fire.levelEquivalentRetirementExpenses,
    retirementAnnualExpenses: fire.retirementAnnualExpenses,
    sustainableLevelSpending: sustainable,
    spendingHeadroom:
        sustainable - fire.levelEquivalentRetirementExpenses,
    shortfall: null,
    candidates: candidates,
    finalPass: finalPass,
  );
}

/// §8.2's three legs at one candidate year.
CandidateYear _evaluate(
  int year, {
  required Household household,
  required Assumptions assumptions,
  required TaxYear taxYear,
  required Map<Id, AssetClass> assetClasses,
  required DateTime asOfDate,
  required BandName band,
  required Projection baseline,
}) {
  final projected = baseline.yearOf(year)!;

  final fire = _fireNumberAt(
    year,
    projection: baseline,
    assumptions: assumptions,
    household: household,
  );

  // Leg 1, a cheap read on balances the baseline already produced.
  final clears =
      projected.netWorth.afterTaxLiquidNetWorth >= fire.fireNumber;

  // Leg 2, also cheap.
  final accounts = {
    for (final entry in projected.accountBalances.entries)
      entry.key: _stateAt(household, entry.key, entry.value),
  };
  // HSA money is bridge-eligible to the extent of that year's actual medical
  // spending, so the figure comes from the health meta-category rather than
  // being assumed away (§8.3).
  final categories = {
    for (final c in household.expenseCategories) c.id: c,
  };
  final medical = sumMoney(household.expenseItems
      .where((i) =>
          categories[i.categoryId]?.metaCategory == MetaCategory.health)
      .map((i) => i.amountIn(
            year,
            currentYear: baseline.years.first.year,
            retirementYear: year,
            categoryDefaultInflation:
                categories[i.categoryId]?.defaultRelativeInflation ?? 0,
          )));

  final bridge = checkBridge(
    household: household,
    accounts: accounts,
    retirementYear: year,
    annualSpending: fire.retirementAnnualExpenses,
    annualQualifiedMedical: medical,
  );

  // Leg 3 is a full multi-decade simulation per candidate year, so it runs
  // only where legs 1 and 2 already pass (§8.2).
  var survives = false;
  if (clears && !bridge.bridgeGapDetected) {
    final fork = project(
      household,
      assumptions: assumptions,
      taxYear: taxYear,
      assetClasses: assetClasses,
      asOfDate: asOfDate,
      retirementYear: year,
      band: band,
    );
    survives = fork.years.every((y) => !y.flags.contains('shortfall'));
  }

  return CandidateYear(
    year: year,
    afterTaxLiquidNetWorth: projected.netWorth.afterTaxLiquidNetWorth,
    fire: fire,
    bridge: bridge,
    clearsFireNumber: clears,
    survivesHorizon: survives,
  );
}

/// §8.1 at a candidate year: the spending stream from that year to the horizon.
FireNumber _fireNumberAt(
  int year, {
  required Projection projection,
  required Assumptions assumptions,
  required Household household,
}) {
  final stream = projection.years
      .where((y) => y.year >= year)
      .map((y) => y.solved.cashFlow.annualExpenses)
      .toList();
  return computeFireNumber(
    stream: stream,
    safeWithdrawalRate: assumptions.safeWithdrawalRate,
  );
}

AccountState _stateAt(Household household, Id id, Money balance) {
  final account = household.accountById(id)!;
  final state = AccountState(account);
  state.balance = balance;
  return state;
}

/// §8.2 across all three bands.
Band<BandResult> solveAllBands(
  Household household, {
  required Assumptions assumptions,
  required TaxYear taxYear,
  required Map<Id, AssetClass> assetClasses,
  required DateTime asOfDate,
}) {
  BandResult run(BandName band) => solveRetirement(
        household,
        assumptions: assumptions,
        taxYear: taxYear,
        assetClasses: assetClasses,
        asOfDate: asOfDate,
        band: band,
      );
  return Band(
    pessimistic: run(BandName.pessimistic),
    expected: run(BandName.expected),
    optimistic: run(BandName.optimistic),
  );
}
