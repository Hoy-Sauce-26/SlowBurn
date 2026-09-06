import '../enums.dart';
import '../types.dart';

/// §3.5. A non-account holding. Never liquid: it becomes spendable only by
/// being sold.
class Asset {
  final Id id;
  final Id householdId;

  /// Whose `TaxUnit` its sale gain is taxed on. Null means jointly held, which
  /// resolves to the household's only `TaxUnit` (invariant 25).
  final Id? personId;

  final String label;
  final AssetCategory category;

  /// Today's estimate, and an ordinary input: re-enter it after an appraisal.
  final Money currentValue;

  /// Purchase price plus improvements to date. Static across the projection.
  final Money costBasis;

  final Rate realAppreciationRate;

  /// `investmentProperty` only, and accrued by the engine each year held.
  final Money accumulatedDepreciation;

  /// `investmentProperty` only. The share of [costBasis] that is land, and so
  /// not depreciable.
  final Rate landFraction;

  final Id? securedByLiabilityId;

  /// Year the household takes ownership. Null means already held.
  final int? acquisitionYear;
  final Id? purchaseFundingAccountId;

  /// Year the household sells it. Requires [saleProceedsAccountId]
  /// (invariant 18).
  final int? plannedSaleYear;
  final Id? saleProceedsAccountId;

  const Asset({
    required this.id,
    required this.householdId,
    this.personId,
    required this.label,
    required this.category,
    required this.currentValue,
    required this.costBasis,
    this.realAppreciationRate = 0,
    this.accumulatedDepreciation = Money.zero,
    this.landFraction = 0.20,
    this.securedByLiabilityId,
    this.acquisitionYear,
    this.purchaseFundingAccountId,
    this.plannedSaleYear,
    this.saleProceedsAccountId,
  });

  /// Whether the household owns this in [year] (§3.5). Before acquisition it is
  /// absent from every net-worth measure; from the sale year forward, likewise.
  bool heldIn(int year) =>
      (acquisitionYear == null || year >= acquisitionYear!) &&
      (plannedSaleYear == null || year < plannedSaleYear!);
}

/// §3.6. A debt, tracked first-class rather than folded into net worth.
class Liability {
  final Id id;
  final Id householdId;
  final Id? personId;
  final String label;
  final LiabilityKind kind;

  final Money currentBalance;
  final Rate interestRate;

  /// Authoritative for cash flow: what actually leaves the account each month.
  final Money monthlyPayment;

  /// The non-amortising portion the servicer collects. Optional, inferred when
  /// null (§3.6).
  final Money? monthlyEscrowAmount;

  /// A component of the escrow total, broken out because it ends on its own
  /// schedule.
  final Money? monthlyPmiAmount;

  /// What fraction of the escrow the household keeps paying after payoff.
  final Rate escrowContinuesAfterPayoff;

  final Money extraPrincipalPayment;

  final DateTime originationDate;
  final int termMonths;

  final Id? securedAssetId;
  final bool isTaxDeductibleInterest;

  const Liability({
    required this.id,
    required this.householdId,
    this.personId,
    required this.label,
    required this.kind,
    required this.currentBalance,
    required this.interestRate,
    required this.monthlyPayment,
    this.monthlyEscrowAmount,
    this.monthlyPmiAmount,
    this.escrowContinuesAfterPayoff = 1.0,
    this.extraPrincipalPayment = Money.zero,
    required this.originationDate,
    required this.termMonths,
    this.securedAssetId,
    this.isTaxDeductibleInterest = false,
  });

  /// The escrow actually charged, entered or inferred (§3.6).
  Money resolvedEscrow({required Money inferredEscrow}) =>
      monthlyEscrowAmount ?? inferredEscrow;

  /// What amortises the loan: the payment less whatever the servicer is only
  /// passing through (§3.6).
  Money principalAndInterest({required Money inferredEscrow}) =>
      monthlyPayment - resolvedEscrow(inferredEscrow: inferredEscrow);
}
