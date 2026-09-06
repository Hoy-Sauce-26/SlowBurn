/// §8.3. Whether the years between retiring and 59½ are actually funded.
///
/// The gap matters because a `traditional` or unqualified `rothEarnings`
/// withdrawal before 59½ carries a penalty on top of ordinary income tax.
library;

import '../entities/household.dart';
import '../enums.dart';
import '../types.dart';
import '../loop/account_state.dart';

class BridgeCheck {
  final int years;
  final Money eligibleAssets;
  final Money cumulativeSpending;

  /// The year does not qualify where this is set, even where the raw number
  /// clears the FIRE target (§8.2).
  final bool bridgeGapDetected;

  const BridgeCheck({
    required this.years,
    required this.eligibleAssets,
    required this.cumulativeSpending,
    required this.bridgeGapDetected,
  });
}

/// §8.3, at a candidate retirement year.
///
/// The comparison ignores both the growth these assets earn and any pension,
/// rental or part-time income arriving during the bridge, so it screens
/// conservatively and leg 3 settles the year.
///
/// It is conservative in a second way the UI has to say out loud: Roth
/// conversion ladders, 72(t)/SEPP and the Rule of 55 are all real routes to
/// tax-deferred money before 59½, none is modelled (§13.3), and so a reported
/// gap may be one a real household could close.
BridgeCheck checkBridge({
  required Household household,
  required Map<Id, AccountState> accounts,
  required int retirementYear,
  required Money annualSpending,
  required Money annualQualifiedMedical,
}) {
  // The bridge ends when the last person still short of 59½ reaches it, since
  // until then some of the household's money is still penalised.
  var bridgeEnd = retirementYear;
  for (final person in household.people) {
    var year = retirementYear;
    while (!person.isPenaltyFreeIn(year) && year < retirementYear + 60) {
      year++;
    }
    if (year > bridgeEnd) bridgeEnd = year;
  }
  final years = bridgeEnd - retirementYear;
  if (years <= 0) {
    return BridgeCheck(
      years: 0,
      eligibleAssets: Money.zero,
      cumulativeSpending: Money.zero,
      bridgeGapDetected: false,
    );
  }

  // The sources that escape the penalty (§8.3).
  var eligible = Money.zero;
  for (final state in accounts.values) {
    switch (state.account.kind) {
      case AccountKind.cashSavings:
      case AccountKind.cashChecking:
      case AccountKind.taxableBrokerage:
        // A brokerage account has no age gate, and its gain portion is taxed
        // and never penalised, so it counts in full.
        eligible += state.balance;
      case AccountKind.rothIra:
        // Withdrawable at any age, tax- and penalty-free, and only to the
        // extent basis has actually been accrued across the accumulation phase
        // (§6.3).
        eligible += minMoney(state.rothContributionBasis, state.balance);
      case AccountKind.hsa:
        // Only to the extent of that year's actual medical spending.
        eligible +=
            minMoney(state.balance, annualQualifiedMedical * years);
      default:
        // taxDeferred and designated Roth are ineligible: the rollover that
        // would free the latter has not happened yet (§8.4.1).
        break;
    }
  }

  final cumulative = annualSpending * years;
  return BridgeCheck(
    years: years,
    eligibleAssets: eligible,
    cumulativeSpending: cumulative,
    bridgeGapDetected: eligible < cumulative,
  );
}
