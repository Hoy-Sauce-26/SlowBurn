import 'package:burn_engine/burn_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'readiness.dart';
import 'tax_year_service.dart';

/// The app's wiring. Every screen reads the projection through here rather than
/// computing anything of its own: if the UI starts working out a number, it
/// will eventually disagree with the engine's and the user will be shown two
/// answers to the same question.

final taxYearServiceProvider = Provider<TaxYearService>((_) => TaxYearService());

final taxYearProvider = FutureProvider<TaxYear>((ref) =>
    ref.watch(taxYearServiceProvider).load(TaxYearService.defaultTaxYearId));

/// How far through setup the household is, and whether its owner has said they
/// are ready to see numbers. Persisted beside the plan rather than inside it.
final setupProgressProvider =
    NotifierProvider<SetupProgressNotifier, SetupProgress>(
        SetupProgressNotifier.new);

class SetupProgressNotifier extends Notifier<SetupProgress> {
  @override
  SetupProgress build() => const SetupProgress();

  void replace(SetupProgress progress) => state = progress;

  /// "I have none of these" is an answer, and it is reversible: entering
  /// something later simply overtakes it.
  void pass(SetupStep step) =>
      state = state.copyWith(passed: {...state.passed, step});

  void unpass(SetupStep step) =>
      state = state.copyWith(passed: {...state.passed}..remove(step));

  void declareReady() => state = state.copyWith(declaredReady: true);
}

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

  /// A child taken out of the plan takes their links with them. Their tuition
  /// and their 529 stay, now for nobody in particular.
  void removeDependent(Id id) => state = state.copyWith(
        taxUnits: [
          for (final t in state.taxUnits)
            t.withDependents(t.dependents.where((d) => d.id != id).toList()),
        ],
        expenseItems: [
          for (final i in state.expenseItems)
            i.dependentId == id ? i.withDependent(null) : i,
        ],
        accounts: [
          for (final a in state.accounts)
            a.beneficiaryId == id ? a.withBeneficiary(null) : a,
        ],
      );

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

  void saveExpenseItem(ExpenseItem i) {
    final items = _upsert(state.expenseItems, i, (e) => e.id);
    // A cost tied to this rent follows it. Doing this here rather than in the
    // editor means it holds however the rent was changed.
    state = state.copyWith(
      expenseItems:
          _followHome(items, homeId: i.id, from: i.startYear, to: i.endYear),
    );
  }
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

  void saveAsset(Asset a) {
    state = state.copyWith(
      assets: _upsert(state.assets, a, (e) => e.id),
      // Sell the house in 2046 and its tax and dues end in 2045 with it.
      expenseItems: _followHome(
        state.expenseItems,
        homeId: a.id,
        from: a.acquisitionYear,
        to: a.plannedSaleYear == null ? null : a.plannedSaleYear! - 1,
      ),
    );
  }
  void removeAsset(Id id) =>
      state = state.copyWith(assets: _without(state.assets, id, (e) => e.id));
}

/// Re-dates every cost attached to a home, so a roof and its bills cannot
/// disagree about when they end.
///
/// Unconditional on purpose. Attaching a cost to a home is the statement that
/// it runs with that home, so a date that no longer matches is stale rather
/// than deliberate; anything meant to outlive the house is left unattached.
List<ExpenseItem> _followHome(
  List<ExpenseItem> items, {
  required Id homeId,
  required int? from,
  required int? to,
}) =>
    [
      for (final item in items)
        if (item.housingId != homeId ||
            (item.startYear == from && item.endYear == to))
          item
        else
          ExpenseItem(
            id: item.id,
            categoryId: item.categoryId,
            label: item.label,
            amount: item.amount,
            frequency: item.frequency,
            startYear: from,
            endYear: to,
            startMonth: item.startMonth,
            endMonth: item.endMonth,
            relativeInflationRate: item.relativeInflationRate,
            phase: item.phase,
            postRetirementAmount: item.postRetirementAmount,
            housingId: item.housingId,
            dependentId: item.dependentId,
          ),
    ];

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
  List<AssetClass> build() => defaults;

  /// A plan saved before a class existed comes back without it, and the field
  /// that offers it would then fall back to whatever sorts first. Stored
  /// classes win where they overlap, and the rest are added.
  void replace(List<AssetClass> classes) {
    final have = classes.map((c) => c.id).toSet();
    state = [
      ...classes,
      ...defaults.where((c) => !have.contains(c.id)),
    ];
  }

  static const defaults = AssetClass.defaults;
}

/// Everything §12 found wrong with the household as entered. Warn-don't-block,
/// so the projection still runs and the findings ride along (§12).
final findingsProvider = Provider<List<Finding>>((ref) => [
      ...validateHousehold(
        ref.watch(householdProvider),
        assetClassIds: {for (final c in ref.watch(assetClassesProvider)) c.id},
      ),
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

  final setup = ref.watch(setupProgressProvider);

  return taxYear.whenData((year) {
    // A household the engine cannot run on gets an empty result rather than a
    // wrong one; the findings say why.
    if (findings.hasBlocking || household.people.isEmpty) {
      throw const ProjectionNotRunnable();
    }
    // And a half-entered one gets nothing at all. The engine answers whatever
    // it is asked, so a plan with a salary and no spending yields a confident
    // retirement year that is a decade early. Nothing computes until the
    // person says the plan is ready to be read.
    if (!setup.showsProjection(household)) {
      throw const ProjectionNotReady();
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

/// Why no projection is being shown: the plan is still being written.
class ProjectionNotReady implements Exception {
  const ProjectionNotReady();
  @override
  String toString() => 'the plan is not ready to be read yet';
}

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

/// Which years each flag was raised in.
///
/// A caveat about "some years" is one nobody can check. Naming them turns it
/// into something a person can look at their own plan and reconcile.
final flagYearsProvider = Provider<Map<String, List<int>>>((ref) {
  final projection = ref.watch(projectionProvider);
  return projection.maybeWhen(
    data: (bands) {
      final years = <String, List<int>>{};
      for (final year in bands.expected.finalPass.years) {
        for (final flag in year.flags) {
          years.putIfAbsent(flag, () => []).add(year.year);
        }
      }
      return years;
    },
    orElse: () => const {},
  );
});

/// "2042", "2042 to 2047", or "2042 to 2047 and 2051 to 2053": a run of years
/// read as spans, since that is how somebody holds them in their head.
String describeYears(List<int> years) {
  if (years.isEmpty) return '';
  final sorted = [...years]..sort();
  final spans = <(int, int)>[];
  var from = sorted.first;
  var to = sorted.first;
  for (final year in sorted.skip(1)) {
    if (year == to + 1) {
      to = year;
    } else {
      spans.add((from, to));
      from = year;
      to = year;
    }
  }
  spans.add((from, to));

  final parts = [
    for (final (a, b) in spans) a == b ? '$a' : '$a to $b',
  ];
  if (parts.length == 1) return parts.single;
  return '${parts.take(parts.length - 1).join(', ')} and ${parts.last}';
}
