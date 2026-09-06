import 'dart:math' as math;

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

/// §8.1's worked household: $70,000 of base spending plus a $22,000 mortgage
/// that runs [mortgageYears] more, leaving $6,000 of continuing escrow.
List<Money> workedStream({required int mortgageYears, int years = 40}) => [
      for (var t = 0; t < years; t++)
        Money.dollars(t < mortgageYears ? 92000 : 76000),
    ];

void main() {
  group('§8.1 the worked example', () {
    // The check the domain doc wrote for an implementation to hit.
    final f = computeFireNumber(
      stream: workedStream(mortgageYears: 10),
      safeWithdrawalRate: 0.035,
    );

    test('the first year is 92,000', () {
      expect(f.retirementAnnualExpenses, Money.dollars(92000));
    });

    test('the level equivalent is 82,231', () {
      expect(f.levelEquivalentRetirementExpenses.dollars,
          closeTo(82231, 1.0));
    });

    test('the FIRE number is 2.35M, not the 2.63M the first year implies', () {
      expect(f.fireNumber.dollars, closeTo(2349470, 1000));

      final naive = Money.dollars(92000) / 0.035;
      expect(naive.dollars, closeTo(2628571, 1.0));
      expect(f.fireNumber < naive, isTrue);
    });

    test('the divergence is flagged so the UI can explain it', () {
      expect(f.retirementSpendingNotLevel, isTrue);
    });
  });

  group('§8.1 the reduction tracks when the expense ends', () {
    Money fireFor(int mortgageYears) => computeFireNumber(
          stream: workedStream(mortgageYears: mortgageYears),
          safeWithdrawalRate: 0.035,
        ).fireNumber;

    final flat = Money.dollars(92000) / 0.035;

    test('a payoff three years in takes 397,000 off', () {
      expect((flat - fireFor(3)).dollars, closeTo(397000, 2000));
    });

    test('a payoff twenty-five years in takes 104,000 off', () {
      expect((flat - fireFor(25)).dollars, closeTo(104000, 2000));
    });

    test('flat spending takes nothing off at all', () {
      // Reproduces retirementAnnualExpenses / safeWithdrawalRate exactly, so
      // the machinery only moves the number when spending actually moves.
      final f = computeFireNumber(
        stream: [for (var t = 0; t < 40; t++) Money.dollars(92000)],
        safeWithdrawalRate: 0.035,
      );
      expect(f.levelEquivalentRetirementExpenses.dollars,
          closeTo(92000, 1.0));
      expect(f.fireNumber.dollars, closeTo(flat.dollars, 1.0));
      expect(f.retirementSpendingNotLevel, isFalse);
    });

    test('the earlier the payoff, the larger the reduction', () {
      expect(fireFor(3) < fireFor(10), isTrue);
      expect(fireFor(10) < fireFor(25), isTrue);
      expect(fireFor(25) < fireFor(40), isTrue);
    });
  });

  group('§8.1 the annuity factor', () {
    test('a zero rate is just the count of years', () {
      expect(annuityFactor(0, 40), 40);
    });

    test('it sums the same range pv does, t = 0 to n-1', () {
      // §8.1's stated closed form is the t = 1..N sum and is smaller by
      // (1 + r). Either range gives the same FIRE number; mixing them does not.
      expect(annuityFactor(0.035, 40), closeTo(21.3551 * 1.035, 1e-3));
      expect(annuityFactor(0.035, 10), closeTo(8.3166 * 1.035, 1e-3));

      var byHand = 0.0;
      for (var t = 0; t < 40; t++) {
        byHand += 1 / math.pow(1.035, t);
      }
      expect(annuityFactor(0.035, 40), closeTo(byHand, 1e-9));
    });

    test('no years means no annuity', () {
      expect(annuityFactor(0.04, 0), 0);
    });
  });

  group('§8.1 degenerate inputs', () {
    test('an empty stream produces nothing rather than dividing by zero', () {
      final f =
          computeFireNumber(stream: const [], safeWithdrawalRate: 0.04);
      expect(f.fireNumber, Money.zero);
    });

    test('a zero withdrawal rate is refused, not divided by', () {
      // Invariant 28 blocks this upstream; the guard is here so a bad
      // scenario cannot produce an infinity.
      final f = computeFireNumber(
        stream: [Money.dollars(50000)],
        safeWithdrawalRate: 0,
      );
      expect(f.fireNumber, Money.zero);
    });

    test('rising spending sizes the plan above the first year', () {
      // Healthcare at +2.5% real is the case this exists for.
      final f = computeFireNumber(
        stream: [
          for (var t = 0; t < 30; t++) Money.dollars(60000 + t * 1000),
        ],
        safeWithdrawalRate: 0.04,
      );
      expect(f.levelEquivalentRetirementExpenses >
          f.retirementAnnualExpenses, isTrue);
      expect(f.retirementSpendingNotLevel, isTrue);
    });
  });
}
