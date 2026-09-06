/// §3.6. A loan, month by month, as the loop carries it through a year.
///
/// The payment is authoritative for cash flow and the payoff date is derived
/// from balance, rate and principal-and-interest. Where the derived payoff and
/// `termMonths` disagree materially the engine keeps the derived figure and
/// raises a flag, matching §12's warn-don't-block posture.
library;

import 'dart:math' as math;

import '../entities/assumptions.dart';
import '../entities/property.dart';
import '../types.dart';

/// The level payment that retires [balance] over [months] at [monthlyRate].
Money amortizationPayment(Money balance, Rate monthlyRate, int months) {
  if (months <= 0 || !balance.isPositive) return Money.zero;
  if (monthlyRate == 0) return balance / months;
  final factor = math.pow(1 + monthlyRate, months);
  return balance * (monthlyRate * factor / (factor - 1));
}

/// A loan's state as the loop carries it.
class LiabilityState {
  final Liability liability;

  Money balance;

  /// Cleared once the balance reaches zero; the escrow may outlive it.
  bool paidOff;

  /// Dropped at its LTV threshold, usually years before payoff.
  bool pmiActive;

  /// Interest paid this year, which §4.3.1 may deduct.
  Money interestPaidThisYear = Money.zero;

  /// Principal retired this year, cash the household actually spent.
  Money principalPaidThisYear = Money.zero;

  /// Escrow paid this year, including any that outlives the loan.
  Money escrowPaidThisYear = Money.zero;

  LiabilityState(this.liability)
      : balance = liability.currentBalance,
        paidOff = !liability.currentBalance.isPositive,
        pmiActive = liability.monthlyPmiAmount != null;

  Id get id => liability.id;

  /// The escrow the servicer collects, entered or inferred (§3.6).
  Money monthlyEscrow({required DateTime asOfDate}) {
    final entered = liability.monthlyEscrowAmount;
    if (entered != null) return entered;
    final elapsed = _monthsElapsed(liability.originationDate, asOfDate);
    final remaining = liability.termMonths - (elapsed < 0 ? 0 : elapsed);
    final scheduled = amortizationPayment(
        liability.currentBalance, liability.interestRate / 12, remaining);
    return (liability.monthlyPayment - scheduled).orZeroIfNegative;
  }

  /// Whether the entered escrow disagrees materially with the inferred one,
  /// which is worth saying and not worth blocking (§3.6).
  bool escrowDiffersFromInferred({required DateTime asOfDate}) {
    final entered = liability.monthlyEscrowAmount;
    if (entered == null) return false;
    final elapsed = _monthsElapsed(liability.originationDate, asOfDate);
    final remaining = liability.termMonths - (elapsed < 0 ? 0 : elapsed);
    final scheduled = amortizationPayment(
        liability.currentBalance, liability.interestRate / 12, remaining);
    final inferred = (liability.monthlyPayment - scheduled).orZeroIfNegative;
    if (!inferred.isPositive && !entered.isPositive) return false;
    final gap = (entered - inferred).cents.abs();
    return gap > (inferred.cents * 0.10).abs() + 2000;
  }

  /// One year of payments (§6).
  ///
  /// [extraPrincipal] is the engine-directed `highInterestDebt` paydown, which
  /// goes to principal ahead of the schedule. [securingAssetValue] drives the
  /// PMI drop, measured against the securing asset's cost basis (§3.9).
  void advanceYear({
    required DateTime asOfDate,
    required Assumptions assumptions,
    required double frac,
    Money extraPrincipal = Money.zero,
    Money? securingAssetBasis,
  }) {
    interestPaidThisYear = Money.zero;
    principalPaidThisYear = Money.zero;
    escrowPaidThisYear = Money.zero;

    final escrow = monthlyEscrow(asOfDate: asOfDate);
    final months = (12 * frac).round();

    if (paidOff) {
      // The escrow account ends at payoff; the obligations inside it do not.
      escrowPaidThisYear =
          escrow * (months * liability.escrowContinuesAfterPayoff);
      return;
    }

    // The engine-directed paydown lands on principal first.
    if (extraPrincipal.isPositive) {
      final applied = minMoney(extraPrincipal, balance);
      balance -= applied;
      principalPaidThisYear += applied;
    }

    final monthlyRate = liability.interestRate / 12;
    final pmi = pmiActive ? (liability.monthlyPmiAmount ?? Money.zero) : Money.zero;
    final principalAndInterest =
        (liability.monthlyPayment - escrow).orZeroIfNegative +
            liability.extraPrincipalPayment;

    for (var m = 0; m < months && balance.isPositive; m++) {
      final interest = balance * monthlyRate;
      var principal = principalAndInterest - interest;
      if (!principal.isPositive) {
        // A payment that does not cover the interest never retires the loan.
        interestPaidThisYear += interest;
        escrowPaidThisYear += escrow;
        continue;
      }
      principal = minMoney(principal, balance);
      balance -= principal;
      interestPaidThisYear += interest;
      principalPaidThisYear += principal;
      escrowPaidThisYear += escrow;

      if (pmiActive && securingAssetBasis != null &&
          securingAssetBasis.isPositive) {
        final ltv = balance.ratioTo(securingAssetBasis);
        if (ltv <= assumptions.pmiTerminationLtv) pmiActive = false;
      }
      if (!balance.isPositive) {
        paidOff = true;
        break;
      }
    }
    // PMI rides inside the escrow, so dropping it lowers what is collected.
    if (!pmiActive && pmi.isPositive) {
      escrowPaidThisYear = (escrowPaidThisYear - pmi * months).orZeroIfNegative;
    }
  }

  /// What this loan cost the household in cash this year (§4.4).
  Money get debtService =>
      interestPaidThisYear + principalPaidThisYear + escrowPaidThisYear;
}

int _monthsElapsed(DateTime from, DateTime to) =>
    (to.year - from.year) * 12 + (to.month - from.month);
