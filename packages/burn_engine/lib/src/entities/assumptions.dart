import '../enums.dart';
import '../types.dart';

/// §3.9. Return rates by class. Ships with defaults the user edits, and is
/// exported, since no bundle can restore an edited rate.
class AssetClass {
  final Id id;
  final AssetClassLabel label;
  final Rate expectedRealReturn;
  final Rate pessimisticRealReturn;
  final Rate optimisticRealReturn;

  /// Dividends and interest paid out, as a fraction of balance. Decomposes the
  /// return; it does not add to it.
  final Rate incomeYield;

  /// The portion of [incomeYield] taxed at preferential rates (§4.3.3).
  final Rate qualifiedIncomeFraction;

  const AssetClass({
    required this.id,
    required this.label,
    required this.expectedRealReturn,
    required this.pessimisticRealReturn,
    required this.optimisticRealReturn,
    this.incomeYield = 0,
    this.qualifiedIncomeFraction = 0,
  });

  /// The set an app seeds a new plan with, and the one place to change what
  /// every household starts from. A stored plan keeps whatever it saved, and
  /// anything added here later reaches existing plans on load.
  static const defaults = [
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
      // A savings account pays interest that roughly keeps pace with
      // inflation and a little over. In real terms that is the interest less
      // the erosion of the principal, which is why the yield is larger than
      // the return: 4% nominal against 2.5% inflation.
      AssetClass(
        id: 'savings',
        label: AssetClassLabel.savings,
        expectedRealReturn: 0.015,
        pessimisticRealReturn: -0.005,
        optimisticRealReturn: 0.025,
        incomeYield: 0.04,
        qualifiedIncomeFraction: 0.0,
      ),
      // A current account pays nothing, so inflation is the whole story.
      AssetClass(
        id: 'cash',
        label: AssetClassLabel.cash,
        expectedRealReturn: -0.025,
        pessimisticRealReturn: -0.035,
        optimisticRealReturn: -0.015,
        incomeYield: 0.0,
        qualifiedIncomeFraction: 0.0,
      ),
  ];

  Rate returnFor(BandName band) => switch (band) {
        BandName.pessimistic => pessimisticRealReturn,
        BandName.expected => expectedRealReturn,
        BandName.optimistic => optimisticRealReturn,
      };

  /// The appreciation half of the return, the distributions having been taken
  /// out (§3.9). Negative where a band's return falls below the yield, which is
  /// permitted: a bad year still pays its dividend while the principal falls.
  Rate appreciationFor(BandName band) => returnFor(band) - incomeYield;
}

enum BandName { pessimistic, expected, optimistic }

/// §3.9. Everything a `Scenario` varies.
class Assumptions {
  /// Display and input conversion only, and the rate §7.4 deflates non-indexed
  /// thresholds by, which makes it load-bearing.
  final Rate generalInflationRate;

  final Rate safeWithdrawalRate;

  /// An ordered subset of the step vocabulary. Must contain
  /// [WaterfallStep.taxableBrokerage] (invariant 29).
  final List<WaterfallStep> contributionWaterfall;

  final List<WithdrawalSource> withdrawalOrder;

  /// Real rate. A liability above this is paid down ahead of investing.
  final Rate highInterestDebtThresholdRate;

  /// Scenario-level master switch. Both this and a person's own
  /// `includeInProjection` must be true for a benefit to appear.
  final bool includeSocialSecurity;

  /// Fraction of unrealised gains realised annually while not drawing down.
  final Rate capitalGainsRealizationRate;

  /// The age the portfolio must survive to, against the youngest person.
  final int projectionHorizonAge;

  final Rate acaMagiCeilingPercentOfFpl;
  final Rate pmiTerminationLtv;
  final Rate assetSaleCostRate;

  /// What each kind of property is expected to do in real terms, used as the
  /// starting point for a new `Asset` rather than asking somebody to guess
  /// (§3.5). A house roughly holds its value against inflation; a car does
  /// not. An asset keeps whatever rate it was saved with, so changing these
  /// moves the suggestion and not the plan.
  final Map<AssetCategory, Rate> assetAppreciationByCategory;

  final Id taxYearId;

  const Assumptions({
    this.generalInflationRate = 0.025,
    this.safeWithdrawalRate = 0.04,
    this.contributionWaterfall = WaterfallStep.values,
    this.withdrawalOrder = WithdrawalSource.values,
    this.highInterestDebtThresholdRate = 0.06,
    this.includeSocialSecurity = true,
    this.capitalGainsRealizationRate = 0.05,
    this.projectionHorizonAge = 95,
    this.acaMagiCeilingPercentOfFpl = 2.00,
    this.pmiTerminationLtv = 0.78,
    this.assetSaleCostRate = 0.06,
    this.assetAppreciationByCategory = defaultAssetAppreciation,
    required this.taxYearId,
  });

  /// Real rates, so zero means "keeps pace with inflation and no more".
  static const defaultAssetAppreciation = {
    AssetCategory.primaryResidence: 0.005,
    AssetCategory.investmentProperty: 0.005,
    AssetCategory.vehicle: -0.10,
    AssetCategory.collectible: 0.0,
    AssetCategory.businessEquity: 0.02,
    AssetCategory.other: 0.0,
  };
}

/// §3.10. A named, saved set of [Assumptions] applied to a household.
///
/// Varies assumptions only: differing household *data* means a cloned
/// household, which is how one job is compared against another (§10.2).
class Scenario {
  final Id id;
  final Id householdId;
  final String label;

  /// Carried rather than referenced, so a scenario keeps the numbers it was
  /// saved with.
  final Assumptions assumptions;

  const Scenario({
    required this.id,
    required this.householdId,
    required this.label,
    required this.assumptions,
  });
}
