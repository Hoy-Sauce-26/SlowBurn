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
  /// Dependents this year: born, and still being supported.
  ///
  /// A child planned for 2031 is entered now with a birth date then, so the
  /// span is bounded at both ends. Without the lower bound they would raise
  /// the household size, the health premium and the Child Tax Credit from the
  /// day they were typed in (§3.2).
  TaxUnit withDependents(List<Dependent> dependents) => TaxUnit(
        id: id,
        householdId: householdId,
        filingStatus: filingStatus,
        stateCode: stateCode,
        localityCode: localityCode,
        dependents: dependents,
        benchmarkPremiumOverride: benchmarkPremiumOverride,
        itemizedDeductionTotal: itemizedDeductionTotal,
      );

  Iterable<Dependent> activeDependents(int year) => dependents.where(
      (d) => year >= d.birthDate.year && year <= d.resolvedSupportEndYear);

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

  /// Entities are immutable and the engine takes the whole household, so an
  /// edit replaces it rather than mutating in place. That is also what makes
  /// undo and the input digest (§10.1) cheap.
  Household copyWith({
    ExpenseSharing? expenseSharing,
    List<TaxUnit>? taxUnits,
    List<Person>? people,
    List<Employer>? employers,
    List<IncomeStream>? incomeStreams,
    List<Account>? accounts,
    List<PayrollDeduction>? payrollDeductions,
    List<Asset>? assets,
    List<Liability>? liabilities,
    List<ExpenseCategory>? expenseCategories,
    List<ExpenseItem>? expenseItems,
    List<OneTimeEvent>? oneTimeEvents,
  }) =>
      Household(
        id: id,
        expenseSharing: expenseSharing ?? this.expenseSharing,
        taxUnits: taxUnits ?? this.taxUnits,
        people: people ?? this.people,
        employers: employers ?? this.employers,
        incomeStreams: incomeStreams ?? this.incomeStreams,
        accounts: accounts ?? this.accounts,
        payrollDeductions: payrollDeductions ?? this.payrollDeductions,
        assets: assets ?? this.assets,
        liabilities: liabilities ?? this.liabilities,
        expenseCategories: expenseCategories ?? this.expenseCategories,
        expenseItems: expenseItems ?? this.expenseItems,
        oneTimeEvents: oneTimeEvents ?? this.oneTimeEvents,
      );

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

  /// Every dependant across the household's returns.
  Iterable<Dependent> get dependents => taxUnits.expand((t) => t.dependents);

  /// The first year of the education spending a 529 is for: its
  /// beneficiary's, or all of it where it names nobody. A line with no start
  /// year is already being paid.
  int? firstTuitionYear(Account account) {
    final meta = {for (final c in expenseCategories) c.id: c.metaCategory};
    final years = expenseItems
        .where((i) =>
            meta[i.categoryId] == MetaCategory.education &&
            (account.beneficiaryId == null ||
                i.dependentId == account.beneficiaryId))
        .map((i) => i.startYear ?? 0);
    return years.isEmpty ? null : years.reduce((a, b) => a < b ? a : b);
  }

  /// Whether [account] holds its later allocation in [year] (§3.9): from
  /// retirement for most, and from the first tuition bill for a 529, which
  /// is the year its own drawdown starts.
  bool movedIn(Account account, int year, {required int? retirementYear}) {
    final from = account.isRestrictedPurpose
        ? firstTuitionYear(account)
        : retirementYear;
    return from != null && year >= from;
  }

  /// Where an unattributed `Asset`, `Liability` or `OneTimeEvent` lands: the
  /// household\'s only tax unit, which exists only while there is exactly one
  /// (invariant 24).
  TaxUnit? get soleTaxUnit => taxUnits.length == 1 ? taxUnits.first : null;
}
