import '../enums.dart';
import '../types.dart';

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

/// §3.2. The container everything else hangs from.
///
/// Membership is by cross-link rather than by a list here: a `TaxUnit` names its
/// household and a `Person` names its tax unit, so there is no second copy of
/// the same fact to disagree with (invariant 25).
class Household {
  final Id id;

  /// How shared expenses are attributed **in reporting only** (§3.2). Expenses
  /// reach no part of §4.3, so this moves no tax figure.
  final ExpenseSharing expenseSharing;

  const Household({
    required this.id,
    this.expenseSharing = ExpenseSharing.pooled,
  });
}
