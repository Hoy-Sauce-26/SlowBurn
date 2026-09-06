import '../enums.dart';
import '../types.dart';
import 'account.dart';
import 'events.dart';
import 'expenses.dart';
import 'income.dart';
import 'payroll.dart';
import 'person.dart';
import 'property.dart';

/// §3.2. One tax return: filing status, jurisdiction, dependents.
class TaxUnit {
  final Id id;
  final Id householdId;
  final FilingStatus filingStatus;
  final String stateCode;
  final String? localityCode;
  final List<Dependent> dependents;

  /// This unit's own second-lowest-cost-silver-plan premium, if known. Null
  /// falls back to the per-person table (§4.3.5).
  final Money? benchmarkPremiumOverride;

  /// A single entered annual figure, held constant in real terms. Used where it
  /// beats the standard deduction (§4.3.2).
  final Money? itemizedDeductionTotal;

  const TaxUnit({
    required this.id,
    required this.householdId,
    required this.filingStatus,
    required this.stateCode,
    this.localityCode,
    this.dependents = const [],
    this.benchmarkPremiumOverride,
    this.itemizedDeductionTotal,
  });

  /// Dependents still supported in [year] (§3.2), which drives head-of-household
  /// qualification and ACA tax-family size.
  Iterable<Dependent> activeDependents(int year) =>
      dependents.where((d) => year <= d.resolvedSupportEndYear);

  /// Dependents under the Child Tax Credit's qualifying age at year end
  /// (§4.3.4). The age itself is tax-year data, so it is passed in.
  int qualifyingChildren(int year, int qualifyingAge) => activeDependents(year)
      .where((d) => year - d.birthDate.year < qualifyingAge)
      .length;
}

/// §3.2. The container everything else hangs from, shaped like §2's tree.
///
/// Membership within it is by cross-link, never by a second list: a `TaxUnit`
/// names its household and a `Person` names its tax unit, so there is no
/// duplicate copy of the same fact to disagree with (invariant 3).
class Household {
  final Id id;

  /// How shared expenses are attributed **in reporting only** (§3.2). Expenses
  /// reach no part of §4.3, so this moves no tax figure.
  final ExpenseSharing expenseSharing;

  final List<TaxUnit> taxUnits;
  final List<Person> people;
  final List<Employer> employers;
  final List<IncomeStream> incomeStreams;
  final List<Account> accounts;
  final List<PayrollDeduction> payrollDeductions;
  final List<Asset> assets;
  final List<Liability> liabilities;
  final List<ExpenseCategory> expenseCategories;
  final List<ExpenseItem> expenseItems;
  final List<OneTimeEvent> oneTimeEvents;

  const Household({
    required this.id,
    this.expenseSharing = ExpenseSharing.pooled,
    this.taxUnits = const [],
    this.people = const [],
    this.employers = const [],
    this.incomeStreams = const [],
    this.accounts = const [],
    this.payrollDeductions = const [],
    this.assets = const [],
    this.liabilities = const [],
    this.expenseCategories = const [],
    this.expenseItems = const [],
    this.oneTimeEvents = const [],
  });

  Person? personById(Id id) =>
      people.where((p) => p.id == id).firstOrNull;

  TaxUnit? taxUnitById(Id id) =>
      taxUnits.where((t) => t.id == id).firstOrNull;

  Account? accountById(Id id) =>
      accounts.where((a) => a.id == id).firstOrNull;

  /// The people filing under one tax unit (§3.2).
  Iterable<Person> peopleIn(TaxUnit unit) =>
      people.where((p) => p.taxUnitId == unit.id);

  /// A person's own streams, which is the scope every per-person cap uses.
  Iterable<IncomeStream> streamsFor(Id personId) =>
      incomeStreams.where((s) => s.personId == personId);

  Iterable<Account> accountsFor(Id personId) =>
      accounts.where((a) => a.personId == personId);

  /// Where an unattributed `Asset`, `Liability` or `OneTimeEvent` lands: the
  /// household\'s only tax unit, which exists only while there is exactly one
  /// (invariant 25).
  TaxUnit? get soleTaxUnit => taxUnits.length == 1 ? taxUnits.first : null;
}
