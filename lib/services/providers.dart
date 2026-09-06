import 'package:burn_engine/burn_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tax_year_service.dart';

/// The app's wiring. Every screen reads the projection through here rather than
/// computing anything of its own: if the UI starts working out a number, it
/// will eventually disagree with the engine's and the user will be shown two
/// answers to the same question.

final taxYearServiceProvider = Provider<TaxYearService>((_) => TaxYearService());

final taxYearProvider = FutureProvider<TaxYear>((ref) =>
    ref.watch(taxYearServiceProvider).load(TaxYearService.defaultTaxYearId));

/// The household under edit. Replaced wholesale on every change, since the
/// entities are immutable and the engine takes the whole thing anyway.
final householdProvider =
    NotifierProvider<HouseholdNotifier, Household>(HouseholdNotifier.new);

class HouseholdNotifier extends Notifier<Household> {
  @override
  Household build() => const Household(id: 'h1');

  void replace(Household household) => state = household;
}

final scenarioProvider =
    NotifierProvider<ScenarioNotifier, Scenario>(ScenarioNotifier.new);

class ScenarioNotifier extends Notifier<Scenario> {
  @override
  Scenario build() => const Scenario(
        id: 'sc1',
        householdId: 'h1',
        label: 'Baseline',
        assumptions: Assumptions(taxYearId: TaxYearService.defaultTaxYearId),
      );

  void replace(Scenario scenario) => state = scenario;
}

/// The `AssetClass` set. Ships with defaults the user edits, and is exported,
/// since no bundle can restore an edited rate (§3.9).
final assetClassesProvider =
    NotifierProvider<AssetClassesNotifier, List<AssetClass>>(
        AssetClassesNotifier.new);

class AssetClassesNotifier extends Notifier<List<AssetClass>> {
  @override
  List<AssetClass> build() => const [
        AssetClass(
          id: 'usStocks',
          label: AssetClassLabel.usStocks,
          expectedRealReturn: 0.05,
          pessimisticRealReturn: 0.02,
          optimisticRealReturn: 0.08,
          incomeYield: 0.013,
          qualifiedIncomeFraction: 1.0,
        ),
        AssetClass(
          id: 'intlStocks',
          label: AssetClassLabel.intlStocks,
          expectedRealReturn: 0.045,
          pessimisticRealReturn: 0.015,
          optimisticRealReturn: 0.075,
          incomeYield: 0.026,
          qualifiedIncomeFraction: 0.7,
        ),
        AssetClass(
          id: 'bonds',
          label: AssetClassLabel.bonds,
          expectedRealReturn: 0.02,
          pessimisticRealReturn: 0.0,
          optimisticRealReturn: 0.03,
          incomeYield: 0.035,
          qualifiedIncomeFraction: 0.0,
        ),
        AssetClass(
          id: 'cash',
          label: AssetClassLabel.cash,
          expectedRealReturn: 0.0,
          pessimisticRealReturn: -0.01,
          optimisticRealReturn: 0.01,
          incomeYield: 0.02,
          qualifiedIncomeFraction: 0.0,
        ),
      ];

  void replace(List<AssetClass> classes) => state = classes;
}

/// Everything §12 found wrong with the household as entered. Warn-don't-block,
/// so the projection still runs and the findings ride along (§12).
final findingsProvider = Provider<List<Finding>>((ref) => [
      ...validateHousehold(ref.watch(householdProvider)),
      ...validateAssumptions(ref.watch(scenarioProvider).assumptions),
    ]);

/// The projection, across all three bands.
///
/// The one place a number comes from. `AsyncValue` because the tax year is read
/// off the asset bundle, and the solve itself is synchronous and fast enough to
/// run on every edit.
final projectionProvider = Provider<AsyncValue<Band<BandResult>>>((ref) {
  final taxYear = ref.watch(taxYearProvider);
  final household = ref.watch(householdProvider);
  final scenario = ref.watch(scenarioProvider);
  final classes = ref.watch(assetClassesProvider);
  final findings = ref.watch(findingsProvider);

  return taxYear.whenData((year) {
    // A household the engine cannot run on gets an empty result rather than a
    // wrong one; the findings say why.
    if (findings.hasBlocking || household.people.isEmpty) {
      throw const ProjectionNotRunnable();
    }
    return solveAllBands(
      household,
      assumptions: scenario.assumptions,
      taxYear: year,
      assetClasses: {for (final c in classes) c.id: c},
      asOfDate: DateTime.now(),
    );
  });
});

/// Why no projection is being shown, as distinct from one that failed.
class ProjectionNotRunnable implements Exception {
  const ProjectionNotRunnable();
  @override
  String toString() => 'not enough entered yet to project';
}

/// The flags the current projection raised, gathered across its years.
final flagsProvider = Provider<Set<String>>((ref) {
  final projection = ref.watch(projectionProvider);
  return projection.maybeWhen(
    data: (bands) => {
      for (final year in bands.expected.finalPass.years) ...year.flags,
    },
    orElse: () => <String>{},
  );
});
