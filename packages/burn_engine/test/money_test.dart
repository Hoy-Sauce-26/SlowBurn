import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

void main() {
  group('Money is integer cents (invariant 10)', () {
    test('dollars round-trip through cents', () {
      expect(Money.dollars(150000).cents, 15000000);
      expect(Money.dollars(0.01).cents, 1);
      expect(Money(15000000).dollars, 150000);
    });

    test('a fractional cent rounds once, at construction', () {
      expect(Money.dollars(0.005).cents, 1);
      expect(Money.dollars(0.004).cents, 0);
    });

    test('scaling rounds to the cent rather than drifting', () {
      // A third of a dollar cannot be represented, so it is rounded and the
      // rounding is visible instead of accumulating in a float.
      final third = Money.dollars(1) / 3;
      expect(third.cents, 33);
      expect((third * 3).cents, 99, reason: 'and the cent is genuinely lost');
    });

    test('addition over many years does not drift', () {
      // The same sum as a double accumulates error; as cents it cannot.
      var total = Money.zero;
      for (var i = 0; i < 10000; i++) {
        total += Money.dollars(0.1);
      }
      expect(total, Money.dollars(1000));
    });

    test('a ratio of two amounts is a rate, not an amount', () {
      expect(Money.dollars(40000).ratioTo(Money.dollars(100000)), 0.4);
      expect(Money.dollars(1).ratioTo(Money.zero), 0,
          reason: 'a zero denominator yields zero rather than infinity');
    });

    test('comparison and sums read as arithmetic', () {
      expect(Money.dollars(10) > Money.dollars(9.99), isTrue);
      expect(minMoney(Money.dollars(3), Money.dollars(5)), Money.dollars(3));
      expect(maxMoney(Money.dollars(3), Money.dollars(5)), Money.dollars(5));
      expect(
        sumMoney([Money.dollars(1), Money.dollars(2), Money.dollars(3)]),
        Money.dollars(6),
      );
    });

    test('only OneTimeEvent carries a sign (§3.8)', () {
      final outflow = OneTimeEvent(
        id: 'e1',
        householdId: 'h1',
        label: 'Truck',
        year: 2030,
        amount: Money.dollars(-40000),
        accountId: 'a1',
      );
      expect(outflow.isOutflow, isTrue);
      expect(outflow.amount.isNegative, isTrue);
    });
  });

  group('Band (§8.2)', () {
    test('maps without letting a band land in the wrong slot', () {
      const b = Band(pessimistic: 1, expected: 2, optimistic: 3);
      final doubled = b.map((v) => v * 2);
      expect(doubled.pessimistic, 2);
      expect(doubled.expected, 4);
      expect(doubled.optimistic, 6);
    });

    test('a reachable band can hold an absence', () {
      const b = Band<Reachable<int>>(
        pessimistic: null,
        expected: 2041,
        optimistic: 2038,
      );
      expect(b.pessimistic, isNull, reason: 'notReachable in the low band');
      expect(b.values.whereType<int>().length, 2);
    });
  });
}
