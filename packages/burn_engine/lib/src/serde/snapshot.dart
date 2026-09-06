/// §10. The digest that decides whether a snapshot is worth writing, and the
/// comparison between any two of them.
library;

import 'dart:convert';

import '../entities/assumptions.dart';
import '../entities/household.dart';
import '../entities/snapshot.dart';
import '../enums.dart';
import '../types.dart';
import 'json.dart';

/// A hash of everything the output moves with (§10.1).
///
/// Household state, the scenario's `Assumptions`, and the `AssetClass` rates it
/// projects under, all three being inputs. Anything else changing is not a plan
/// change, and a snapshot written for it would be noise in the history.
String inputDigest({
  required Household household,
  required Assumptions assumptions,
  required List<AssetClass> assetClasses,
}) {
  final canonical = jsonEncode(exportToMap(ExportBundle(
    household: household,
    scenarios: [
      Scenario(
        id: 'digest',
        householdId: household.id,
        label: 'digest',
        assumptions: assumptions,
      ),
    ],
    assetClasses: assetClasses,
  )));
  // FNV-1a: stable across runs, which a Dart `hashCode` is not, and that
  // stability is the whole point of comparing today's digest to yesterday's.
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(canonical)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// §10.1. What to do with a proposed snapshot, given the history.
enum SnapshotAction {
  /// Nothing the output moves with has changed since the last snapshot.
  skip,

  /// Write it, and nothing needs removing.
  write,

  /// Write it and delete the day's superseded `auto` one, so a sitting
  /// collapses to the state the user settled on rather than to the first thing
  /// they typed.
  writeReplacingToday,
}

/// §10.1's rules, over the snapshots already stored for one scenario.
({SnapshotAction action, ProjectionSnapshot? supersedes}) snapshotDecision({
  required List<ProjectionSnapshot> existing,
  required SnapshotTrigger trigger,
  required String digest,
  required DateTime asOfDate,
}) {
  // A deliberate checkpoint always writes: it is not throttled.
  if (trigger == SnapshotTrigger.manual) {
    return (action: SnapshotAction.write, supersedes: null);
  }

  final sorted = [...existing]
    ..sort((a, b) => b.asOfDate.compareTo(a.asOfDate));

  // Nothing actually changed, so there is nothing to record.
  if (sorted.isNotEmpty && sorted.first.inputDigest == digest) {
    return (action: SnapshotAction.skip, supersedes: null);
  }

  final today = sorted
      .where((s) =>
          s.trigger == SnapshotTrigger.auto && _sameDay(s.asOfDate, asOfDate))
      .firstOrNull;
  if (today != null) {
    return (action: SnapshotAction.writeReplacingToday, supersedes: today);
  }
  return (action: SnapshotAction.write, supersedes: null);
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// One quantity's movement between two snapshots, or the transition where a
/// side is unreachable.
class Delta<T> {
  final T? before;
  final T? after;

  const Delta(this.before, this.after);

  bool get becameReachable => before == null && after != null;
  bool get becameUnreachable => before != null && after == null;

  /// There being no arithmetic between a year and its absence, the comparison
  /// names the transition instead (§10.2).
  bool get isTransition => becameReachable || becameUnreachable;
}

/// §10.2. Computed on demand and not itself a stored entity.
class SnapshotComparison {
  final ProjectionSnapshot older;
  final ProjectionSnapshot newer;

  final Band<Delta<int>> retirementYear;
  final Band<Delta<Money>> fireNumber;
  final Band<Delta<Money>> sustainableLevelSpending;

  final Money netWorthDelta;
  final Money liquidNetWorthDelta;
  final Money investableNetWorthDelta;
  final Money afterTaxLiquidNetWorthDelta;
  final Rate savingsRateDelta;

  /// Null where both sides carry the same `asOfDate`, which is what comparing
  /// two hypotheticals looks like: there is no time axis to report (§10.2).
  final Duration? elapsed;

  /// What differs between the two sides. More than one is possible, and a
  /// comparison that names several is saying no single cause owns the delta.
  final Set<String> differsBy;

  const SnapshotComparison({
    required this.older,
    required this.newer,
    required this.retirementYear,
    required this.fireNumber,
    required this.sustainableLevelSpending,
    required this.netWorthDelta,
    required this.liquidNetWorthDelta,
    required this.investableNetWorthDelta,
    required this.afterTaxLiquidNetWorthDelta,
    required this.savingsRateDelta,
    required this.elapsed,
    required this.differsBy,
  });

  /// Whether part of the delta is a change in the bundled rules rather than a
  /// change in the plan, in which case attributing it to the household would be
  /// wrong (§10.2).
  bool get crossesTaxYears => differsBy.contains('taxYearId');
}

/// §10.2, between any two snapshots.
///
/// The two sides need not share a scenario or a household: comparing two cloned
/// households is how a user sees one job against another (§3.10).
SnapshotComparison compareSnapshots(
  ProjectionSnapshot older,
  ProjectionSnapshot newer, {
  /// Which scenario each side belongs to, so the comparison can say whether the
  /// assumptions differ. Omitted where the caller does not have them.
  Scenario? olderScenario,
  Scenario? newerScenario,
}) {
  Band<Delta<T>> band<T>(
    Band<Reachable<T>> a,
    Band<Reachable<T>> b,
  ) =>
      Band(
        pessimistic: Delta(a.pessimistic, b.pessimistic),
        expected: Delta(a.expected, b.expected),
        optimistic: Delta(a.optimistic, b.optimistic),
      );

  final differs = <String>{};
  if (older.taxYearId != newer.taxYearId) differs.add('taxYearId');
  if (older.scenarioId != newer.scenarioId) differs.add('scenario');
  if (olderScenario != null &&
      newerScenario != null &&
      olderScenario.householdId != newerScenario.householdId) {
    differs.add('household');
  }
  if (olderScenario != null &&
      newerScenario != null &&
      jsonEncode(_assumptionsOf(olderScenario)) !=
          jsonEncode(_assumptionsOf(newerScenario))) {
    differs.add('assumptions');
  }

  final sameDay = _sameDay(older.asOfDate, newer.asOfDate);

  return SnapshotComparison(
    older: older,
    newer: newer,
    retirementYear: band(older.retirementYear, newer.retirementYear),
    fireNumber: band(older.fireNumber, newer.fireNumber),
    sustainableLevelSpending: band(
        older.sustainableLevelSpending, newer.sustainableLevelSpending),
    netWorthDelta: newer.netWorth - older.netWorth,
    liquidNetWorthDelta: newer.liquidNetWorth - older.liquidNetWorth,
    investableNetWorthDelta:
        newer.investableNetWorth - older.investableNetWorth,
    afterTaxLiquidNetWorthDelta:
        newer.afterTaxLiquidNetWorth - older.afterTaxLiquidNetWorth,
    savingsRateDelta: newer.savingsRate - older.savingsRate,
    elapsed: sameDay ? null : newer.asOfDate.difference(older.asOfDate),
    differsBy: differs,
  );
}

Map<String, dynamic> _assumptionsOf(Scenario s) =>
    (exportToMap(ExportBundle(
      household: Household(id: s.householdId),
      scenarios: [s],
      assetClasses: const [],
    ))['scenarios'] as List<dynamic>)
        .first['assumptions'] as Map<String, dynamic>;
