/// §6.2 and §6.3. An account as the loop carries it through a year.
///
/// Balances and both bases are **engine state**, not inputs: the user enters an
/// opening figure and the loop maintains it from there. Leaving them frozen
/// taxes reinvested distributions twice, re-realises the same gains forever,
/// and fires §8.3's bridge test on plans that are comfortably funded.
library;

import 'dart:math' as math;

import '../entities/account.dart';
import '../entities/assumptions.dart';
import '../enums.dart';
import '../pipeline/allocation.dart';
import '../types.dart';

class AccountState {
  final Account account;

  Money balance;
  Money costBasis;
  Money rothContributionBasis;

  /// Flows accumulated this year, for the mid-year convention (§6.2).
  Money _netFlows = Money.zero;

  /// Gains realised this year, which §4.3.1 taxes and §6.3 adds to basis.
  Money realizedGain = Money.zero;

  /// Distributions credited this year: taxed now, so they raise basis (§6.3).
  Money investmentIncome = Money.zero;

  AccountState(this.account)
      : balance = account.balance,
        // A bank balance is all after-tax dollars, whatever was entered for
        // it. Left as a zero basis, drawing $40,000 from savings would be
        // taxed as though every dollar were gain (§6.3).
        costBasis = account.kind.isCash
            ? maxMoney(account.costBasis, account.balance)
            : account.costBasis,
        rothContributionBasis = account.rothContributionBasis;

  Id get id => account.id;
  bool get isTaxable => account.taxTreatment == TaxTreatment.taxable;
  bool get isRoth => account.taxTreatment == TaxTreatment.roth;

  Money get unrealizedGain => (balance - costBasis).orZeroIfNegative;

  /// Money in. [afterTax] dollars bring their basis with them, or the whole of
  /// an inheritance reads as gain on the way out (§6.3).
  void deposit(Money amount, {bool afterTax = true}) {
    if (!amount.isPositive) return;
    balance += amount;
    _netFlows += amount;
    if (isTaxable && afterTax) costBasis += amount;
  }

  /// An employee contribution, which raises Roth basis. Employer match does
  /// not: matched dollars are not employee contributions and do not carry the
  /// same penalty-free treatment (§6.3).
  void contribute(Money amount) {
    if (!amount.isPositive) return;
    balance += amount;
    _netFlows += amount;
    if (isRoth) rothContributionBasis += amount;
    if (isTaxable) costBasis += amount;
  }

  void creditEmployerMatch(Money amount) {
    if (!amount.isPositive) return;
    balance += amount;
    _netFlows += amount;
    if (isTaxable) costBasis += amount;
  }

  /// Money out, with basis reduced **pro rata at the ratio the draw actually
  /// saw** (§6.3).
  ///
  /// The denominator is the balance the outflow was taken from, not the closing
  /// balance maintenance runs against: $40,000 out of $100,000 is 40% of the
  /// basis, not the 67% a $60,000 closing balance would imply.
  ///
  /// Returns what was actually taken, which is less than asked where the
  /// balance could not cover it.
  Money withdraw(Money amount, {bool fromRothBasis = false}) {
    if (!amount.isPositive) return Money.zero;
    final taken = minMoney(amount, balance);
    if (taken.isZero) return Money.zero;

    final ratio = taken.ratioTo(balance);
    if (isTaxable) costBasis -= costBasis * ratio;
    if (isRoth && fromRothBasis) {
      rothContributionBasis =
          (rothContributionBasis - taken).orZeroIfNegative;
    }

    balance -= taken;
    _netFlows -= taken;
    return taken;
  }

  /// The share of a taxable withdrawal that is gain rather than return of
  /// capital (§8.4.1). Read **before** the withdrawal, since the ratio moves.
  Money gainPortionOf(Money amount) {
    if (!isTaxable || !balance.isPositive) return Money.zero;
    final gainShare = 1 - costBasis.ratioTo(balance);
    return amount * (gainShare < 0 ? 0 : gainShare);
  }

  /// Distributions stay in the account and compound, and are taxed anyway, so
  /// they raise basis without moving the balance (§4.3.1, §6.3).
  void creditInvestmentIncome(Money amount) {
    if (!amount.isPositive) return;
    investmentIncome += amount;
    if (isTaxable) costBasis += amount;
  }

  /// Rebalancing realises a share of the unrealised gain, which is already
  /// taxed and so raises basis (§6.3).
  ///
  /// The `max(0, …)` in [unrealizedGain] means the engine never generates a
  /// capital loss, which is why loss carryforwards are deferred (§13.2).
  Money realizeGains(Rate realizationRate) {
    final gain = unrealizedGain * realizationRate;
    realizedGain += gain;
    costBasis += gain;
    return gain;
  }

  /// §6.2. Growth on the opening balance for the whole year, and on this year's
  /// flows for half of it.
  ///
  /// Growing the closing balance as though every flow had landed on January 1
  /// hands each December dollar a full year of compounding it never earned,
  /// about 2.5% per contribution at a 5% return, for the whole accumulation
  /// phase.
  void grow({
    required Map<Id, AssetClass> assetClasses,
    required BandName band,
    required double frac,
    bool retired = false,
  }) {
    final r = blendedReturn(account, assetClasses, band, retired: retired);
    final opening = balance - _netFlows;
    final grown = opening * math.pow(1 + r, frac) +
        _netFlows * math.pow(1 + r, frac / 2);
    balance = grown.orZeroIfNegative;
    _netFlows = Money.zero;
  }

  /// What this account looks like once the year is done.
  Account snapshot() => Account(
        id: account.id,
        personId: account.personId,
        label: account.label,
        kind: account.kind,
        taxTreatment: account.taxTreatment,
        limitFamily: account.limitFamily,
        balance: balance,
        costBasis: costBasis,
        rothContributionBasis: rothContributionBasis,
        rothFirstContributionYear: account.rothFirstContributionYear,
        contribution: account.contribution,
        employerId: account.employerId,
        allocationMode: account.allocationMode,
        assetAllocationId: account.assetAllocationId,
        allocationWeights: account.allocationWeights,
        isRestrictedPurpose: account.isRestrictedPurpose,
        targetBalanceMonths: account.targetBalanceMonths,
        beneficiaryId: account.beneficiaryId,
      );
}
