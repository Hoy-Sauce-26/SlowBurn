/// §8.1. What the portfolio has to be worth, given what retirement costs.
///
/// Retirement spending is a **stream**, and the FIRE number prices the stream.
/// Sizing off the first year alone would charge the household for a mortgage
/// payment for the rest of their life when the mortgage retires in 2041, and
/// §3.6 promises the opposite.
library;

import 'dart:math' as math;

import '../types.dart';

class FireNumber {
  /// The first year of the stream, the figure a user recognises as "what I'll
  /// spend in retirement". Reported, and it does not size the plan.
  final Money retirementAnnualExpenses;

  /// The constant annual spend with the same present value as the whole
  /// projected stream. This is what sizes the plan.
  final Money levelEquivalentRetirementExpenses;

  final Money fireNumber;

  /// Raised where the two diverge by more than a trivial amount, so the UI can
  /// say why the plan is sized below the first year's spending.
  final bool retirementSpendingNotLevel;

  const FireNumber({
    required this.retirementAnnualExpenses,
    required this.levelEquivalentRetirementExpenses,
    required this.fireNumber,
    required this.retirementSpendingNotLevel,
  });
}

/// The present-value factor of a level $1 over [n] years at [r] (§8.1).
///
/// Summed over `t = 0 .. n−1`, matching the range `pv` uses, which is §8.1's
/// `(1 + r) × (1 − (1 + r)^−N) / r`. Spending starts at retirement rather than
/// a year after it, so `t` begins at 0 and the textbook factor, which sums
/// from 1, needs the `(1 + r)`.
double annuityFactor(Rate r, int n) {
  if (n <= 0) return 0;
  if (r == 0) return n.toDouble();
  return (1 - math.pow(1 + r, -n)) / r * (1 + r);
}

/// §8.1, over a spending stream already projected across retirement.
///
/// [stream] is `S(t)` for `t = 0 .. N−1`: `annualExpenses` in each retirement
/// year, with debt service dropping at payoff and health insurance following
/// its ACA-to-Medicare schedule.
FireNumber computeFireNumber({
  required List<Money> stream,
  required Rate safeWithdrawalRate,
}) {
  final r = safeWithdrawalRate;
  final n = stream.length;
  if (n == 0 || r <= 0) {
    return const FireNumber(
      retirementAnnualExpenses: Money.zero,
      levelEquivalentRetirementExpenses: Money.zero,
      fireNumber: Money.zero,
      retirementSpendingNotLevel: false,
    );
  }

  var pv = 0.0;
  for (var t = 0; t < n; t++) {
    pv += stream[t].dollars / math.pow(1 + r, t);
  }
  final annuity = annuityFactor(r, n);

  final level = Money.dollars(pv / annuity);
  final first = stream.first;

  // A household whose retirement spending genuinely is flat gets
  // `pv / annuity = S(0)` and the familiar `spending / SWR`, unchanged, so the
  // machinery only moves the number when spending actually moves.
  final divergence = (level - first).cents.abs();
  return FireNumber(
    retirementAnnualExpenses: first,
    levelEquivalentRetirementExpenses: level,
    fireNumber: level / r,
    retirementSpendingNotLevel:
        first.isPositive && divergence > (first.cents * 0.005).abs(),
  );
}
