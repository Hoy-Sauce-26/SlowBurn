/// §5. The four net-worth measures, recomputed every projected year.
library;

import '../entities/assumptions.dart';
import '../entities/household.dart';
import '../entities/property.dart';
import '../enums.dart';
import '../types.dart';
import 'account_state.dart';
import 'amortization.dart';

class NetWorth {
  final Money netWorth;
  final Money liquidNetWorth;
  final Money investableNetWorth;
  final Money afterTaxLiquidNetWorth;

  const NetWorth({
    required this.netWorth,
    required this.liquidNetWorth,
    required this.investableNetWorth,
    required this.afterTaxLiquidNetWorth,
  });
}

/// §5 and §8.2. All four, for one year.
///
/// [projectedLtcgRate] and [effectiveRetirementTaxRate] are the cheap estimates
/// §8.2 uses to price the tax already embedded in a balance. An HSA is priced
/// as tax-deferred, since only the part eventually spent on qualified medical
/// costs escapes tax and the model cannot know how much that will be. That
/// understates the best-treated account in the plan, which is the safe
/// direction for a figure that gates a retirement date.
NetWorth computeNetWorth({
  required Household household,
  required Map<Id, AccountState> accounts,
  required Map<Id, LiabilityState> liabilities,
  required Map<Id, Money> assetValues,
  required Assumptions assumptions,
  required Money annualExpenses,
  required int year,
  required Rate projectedLtcgRate,
  required Rate effectiveRetirementTaxRate,
}) {
  final balances = sumMoney(accounts.values.map((a) => a.balance));

  final heldAssets = sumMoney(household.assets
      .where((a) => a.heldIn(year))
      .map((a) => assetValues[a.id] ?? a.currentValue));

  final originatedDebt = sumMoney(liabilities.values
      .where((l) => l.liability.originationDate.year <= year)
      .map((l) => l.balance));

  // Accounts only, and unsecured debt only once originated: an Asset reaches
  // this measure only after a sale deposits its proceeds (§3.5).
  final unrestricted = sumMoney(accounts.values
      .where((a) => !a.account.isRestrictedPurpose)
      .map((a) => a.balance));
  final unsecuredDebt = sumMoney(liabilities.values
      .where((l) =>
          l.liability.securedAssetId == null &&
          l.liability.originationDate.year <= year)
      .map((l) => l.balance));
  final liquid = unrestricted - unsecuredDebt;

  // The target amount, not the account itself, so a buffer holding more than
  // its target leaves the excess here (§4.5).
  final bufferTargets = sumMoney(accounts.values
      .where((a) => a.account.targetBalanceMonths != null)
      .map((a) =>
          annualExpenses * (a.account.targetBalanceMonths! / 12)));

  final taxableEmbedded = sumMoney(accounts.values
      .where((a) => a.isTaxable)
      .map((a) => a.unrealizedGain * projectedLtcgRate));
  final deferredEmbedded = sumMoney(accounts.values
      .where((a) =>
          a.account.taxTreatment == TaxTreatment.taxDeferred ||
          a.account.taxTreatment == TaxTreatment.hsaTriple)
      .map((a) => a.balance * effectiveRetirementTaxRate));

  return NetWorth(
    netWorth: balances + heldAssets - originatedDebt,
    liquidNetWorth: liquid,
    investableNetWorth: liquid - bufferTargets,
    afterTaxLiquidNetWorth: liquid - taxableEmbedded - deferredEmbedded,
  );
}

/// §3.5. What an asset sale moves, when §6 reaches `plannedSaleYear`.
class AssetSale {
  final Money grossProceeds;
  final Money sellingCosts;
  final Money netProceeds;

  /// Taxed at its own flat rate, and not shelterable by §121.
  final Money recapture;

  /// Feeds `realizedLongTermGains` in §4.3.1.
  final Money taxableGain;

  /// Negative net proceeds after retiring the secured loan: an underwater sale.
  final bool underwater;

  const AssetSale({
    required this.grossProceeds,
    required this.sellingCosts,
    required this.netProceeds,
    required this.recapture,
    required this.taxableGain,
    required this.underwater,
  });
}

AssetSale computeAssetSale(
  Asset asset, {
  required Money projectedValue,
  required Assumptions assumptions,
  required Money section121Exclusion,
  required Rate unrecapturedRate,
  Money securedBalance = Money.zero,
}) {
  final sellingCosts = asset.category.carriesSaleCost
      ? projectedValue * assumptions.assetSaleCostRate
      : Money.zero;
  var netProceeds = projectedValue - sellingCosts;

  final adjustedBasis = asset.costBasis - asset.accumulatedDepreciation;
  final gain = (netProceeds - adjustedBasis).orZeroIfNegative;

  // Depreciation is claimed every year and paid for once: recapture comes out
  // before the exclusion, since §121 cannot shelter it (§3.5).
  final recapture = minMoney(asset.accumulatedDepreciation, gain);
  final exclusion = asset.category == AssetCategory.primaryResidence
      ? section121Exclusion
      : Money.zero;
  final taxableGain = (gain - recapture - exclusion).orZeroIfNegative;

  netProceeds -= securedBalance;

  return AssetSale(
    grossProceeds: projectedValue,
    sellingCosts: sellingCosts,
    netProceeds: netProceeds,
    recapture: recapture,
    taxableGain: taxableGain,
    underwater: netProceeds.isNegative,
  );
}

/// §3.5. Straight-line depreciation on a held investment property, capped so
/// accumulated depreciation never exceeds the depreciable basis.
Money annualDepreciationFor(
  Asset asset, {
  required double residentialDepreciationYears,
}) {
  if (asset.category != AssetCategory.investmentProperty) return Money.zero;
  final depreciable = asset.costBasis * (1 - asset.landFraction);
  final annual = depreciable / residentialDepreciationYears;
  final room = (depreciable - asset.accumulatedDepreciation).orZeroIfNegative;
  return minMoney(annual, room);
}
