import '../enums.dart';
import '../types.dart';
import 'spanned.dart';

/// §3.4.5. Pre-tax money that is spent rather than saved.
///
/// Structurally the sibling of `Contribution`: the same three tax flags and the
/// same place in §4.1 and §4.3, with no balance behind it.
class PayrollDeduction with Spanned {
  final Id id;
  final Id personId;
  final String label;
  final PayrollDeductionKind kind;

  /// Normalised to annual, and scaled by [activeFraction] in the deduction's
  /// first and last year (§3.3).
  final Money annualAmount;

  final bool reducesFederalTaxableIncome;
  final bool reducesStateTaxableIncome;
  final bool reducesFicaWages;

  /// Which category this spending would otherwise have appeared under, for
  /// reporting only.
  final Id? expenseCategoryId;

  @override
  final int? startYear;
  @override
  final int? endYear;
  @override
  final int? startMonth;
  @override
  final int? endMonth;

  const PayrollDeduction({
    required this.id,
    required this.personId,
    required this.label,
    required this.kind,
    required this.annualAmount,
    this.reducesFederalTaxableIncome = true,
    this.reducesStateTaxableIncome = true,
    this.reducesFicaWages = false,
    this.expenseCategoryId,
    this.startYear,
    this.endYear,
    this.startMonth,
    this.endMonth,
  });

  Money resolvedAmount(int year) => annualAmount * activeFraction(year);
}
