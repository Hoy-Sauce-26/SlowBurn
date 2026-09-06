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

  /// Upsert by id, since an editor either creates or edits and the screens
  /// should not have to know which.
  static List<T> _upsert<T>(List<T> items, T item, Id Function(T) idOf) {
    final index = items.indexWhere((e) => idOf(e) == idOf(item));
    final copy = [...items];
    if (index >= 0) {
      copy[index] = item;
    } else {
      copy.add(item);
    }
    return copy;
  }

  static List<T> _without<T>(List<T> items, Id id, Id Function(T) idOf) =>
      items.where((e) => idOf(e) != id).toList();

  void savePerson(Person p) =>
      state = state.copyWith(people: _upsert(state.people, p, (e) => e.id));
  /// Removing the last person filing a return removes the return with them.
  /// A tax unit nobody files is not a state anyone means to be in, and it would
  /// otherwise sit on the screen as a form for a household with no one in it.
  void removePerson(Id id) {
    final people = _without(state.people, id, (e) => e.id);
    state = state.copyWith(
      people: people,
      taxUnits: state.taxUnits
          .where((u) => people.any((p) => p.taxUnitId == u.id))
          .toList(),
    );
  }

  void saveTaxUnit(TaxUnit t) => state =
      state.copyWith(taxUnits: _upsert(state.taxUnits, t, (e) => e.id));
  void removeTaxUnit(Id id) => state =
      state.copyWith(taxUnits: _without(state.taxUnits, id, (e) => e.id));

  void saveEmployer(Employer e) => state =
      state.copyWith(employers: _upsert(state.employers, e, (x) => x.id));
  void removeEmployer(Id id) => state =
      state.copyWith(employers: _without(state.employers, id, (x) => x.id));

  void saveIncomeStream(IncomeStream s) => state = state.copyWith(
      incomeStreams: _upsert(state.incomeStreams, s, (e) => e.id));
  void removeIncomeStream(Id id) => state = state.copyWith(
      incomeStreams: _without(state.incomeStreams, id, (e) => e.id));

  void saveAccount(Account a) =>
      state = state.copyWith(accounts: _upsert(state.accounts, a, (e) => e.id));
  void removeAccount(Id id) =>
      state = state.copyWith(accounts: _without(state.accounts, id, (e) => e.id));

  void saveCategory(ExpenseCategory c) => state = state.copyWith(
      expenseCategories: _upsert(state.expenseCategories, c, (e) => e.id));
  void removeCategory(Id id) => state = state.copyWith(
      expenseCategories: _without(state.expenseCategories, id, (e) => e.id));

  void saveExpenseItem(ExpenseItem i) => state = state.copyWith(
      expenseItems: _upsert(state.expenseItems, i, (e) => e.id));
  void removeExpenseItem(Id id) => state = state.copyWith(
      expenseItems: _without(state.expenseItems, id, (e) => e.id));

  void saveLiability(Liability l) => state = state.copyWith(
      liabilities: _upsert(state.liabilities, l, (e) => e.id));
  void removeLiability(Id id) => state = state.copyWith(
      liabilities: _without(state.liabilities, id, (e) => e.id));

  void savePayrollDeduction(PayrollDeduction d) => state = state.copyWith(
      payrollDeductions: _upsert(state.payrollDeductions, d, (e) => e.id));
  void removePayrollDeduction(Id id) => state = state.copyWith(
      payrollDeductions: _without(state.payrollDeductions, id, (e) => e.id));

  void saveOneTimeEvent(OneTimeEvent e) => state = state.copyWith(
      oneTimeEvents: _upsert(state.oneTimeEvents, e, (x) => x.id));
  void removeOneTimeEvent(Id id) => state = state.copyWith(
      oneTimeEvents: _without(state.oneTimeEvents, id, (x) => x.id));

  void saveAsset(Asset a) =>
      state = state.copyWith(assets: _upsert(state.assets, a, (e) => e.id));
  void removeAsset(Id id) =>
      state = state.copyWith(assets: _without(state.assets, id, (e) => e.id));
}

/// A fresh id. Local-only storage means nothing has to coordinate these, so
/// time plus a counter is enough and reads better in an export than a uuid.
String newId(String prefix) {
  _idCounter++;
  return '$prefix-${DateTime.now().millisecondsSinceEpoch}-$_idCounter';
}

int _idCounter = 0;

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
