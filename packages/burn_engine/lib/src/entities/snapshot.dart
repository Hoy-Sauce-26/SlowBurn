import '../enums.dart';
import '../types.dart';

/// §3.13. A frozen record of what the plan looked like on a date.
///
/// Immutable once written and never recomputed in place (invariant 18): a plan
/// change produces a new snapshot, which is what makes §10.2's comparison
/// mean anything.
class ProjectionSnapshot {
  final Id id;
  final Id scenarioId;
  final DateTime asOfDate;
  final SnapshotTrigger trigger;
  final String? label;

  /// A hash of the inputs behind this run, so a rerun over unchanged inputs is
  /// recognisable as one (§10.1).
  final String inputDigest;

  /// Which bundled ruleset produced these figures. Two snapshots under
  /// different tax years are not cleanly comparable, and §10.2 says so rather
  /// than reporting a bracket change as progress.
  final Id taxYearId;

  /// Per band, and unreachable where no year qualifies within the horizon.
  final Band<Reachable<int>> retirementYear;
  final Band<Reachable<Money>> fireNumber;

  /// The headline a household with a fixed retirement date tracks, where one
  /// solving for a date tracks [retirementYear] (§9.4).
  final Band<Reachable<Money>> sustainableLevelSpending;

  final Money netWorth;
  final Money liquidNetWorth;
  final Money investableNetWorth;
  final Money afterTaxLiquidNetWorth;

  final Rate savingsRate;

  const ProjectionSnapshot({
    required this.id,
    required this.scenarioId,
    required this.asOfDate,
    required this.trigger,
    this.label,
    required this.inputDigest,
    required this.taxYearId,
    required this.retirementYear,
    required this.fireNumber,
    required this.sustainableLevelSpending,
    required this.netWorth,
    required this.liquidNetWorth,
    required this.investableNetWorth,
    required this.afterTaxLiquidNetWorth,
    required this.savingsRate,
  });
}
