import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

List<TaxBracket> schedule(List<(num?, double)> rows) => [
      for (final (upTo, rate) in rows)
        TaxBracket(
          upTo: upTo == null ? null : Money.dollars(upTo),
          rate: rate,
        ),
    ];

void main() {
  final ordinary = schedule([(10000, 0.10), (40000, 0.20), (null, 0.30)]);

  group('applyBrackets', () {
    test('charges each band only on the slice inside it', () {
      expect(applyBrackets(Money.dollars(5000), ordinary), Money.dollars(500));
      expect(applyBrackets(Money.dollars(10000), ordinary), Money.dollars(1000));
      expect(applyBrackets(Money.dollars(25000), ordinary),
          Money.dollars(1000 + 3000));
      expect(applyBrackets(Money.dollars(60000), ordinary),
          Money.dollars(1000 + 6000 + 6000));
    });

    test('zero and negative income owe nothing', () {
      expect(applyBrackets(Money.zero, ordinary), Money.zero);
      expect(applyBrackets(Money.dollars(-100), ordinary), Money.zero);
    });

    test('the effective rate stays below the marginal rate', () {
      final tax = applyBrackets(Money.dollars(60000), ordinary);
      expect(tax.ratioTo(Money.dollars(60000)), lessThan(0.30));
    });
  });

  group('applyStackedBrackets (§4.3.3)', () {
    final ltcg = schedule([(48350, 0.0), (533400, 0.15), (null, 0.20)]);

    test('gains below the 0% ceiling with no ordinary income are free', () {
      expect(
        applyStackedBrackets(Money.dollars(40000),
            stackedOn: Money.zero, brackets: ltcg),
        Money.zero,
      );
    });

    test('ordinary income uses the 0% room first', () {
      // $40,000 ordinary leaves $8,350 of the 0% band; the remaining $11,650 of
      // a $20,000 gain is charged at 15%.
      final tax = applyStackedBrackets(
        Money.dollars(20000),
        stackedOn: Money.dollars(40000),
        brackets: ltcg,
      );
      expect(tax, Money.dollars(11650) * 0.15);
    });

    test('ordinary income past the ceiling leaves no free room at all', () {
      final tax = applyStackedBrackets(
        Money.dollars(20000),
        stackedOn: Money.dollars(100000),
        brackets: ltcg,
      );
      expect(tax, Money.dollars(20000) * 0.15);
    });

    test('stacking never charges less than not stacking', () {
      final free = applyStackedBrackets(Money.dollars(20000),
          stackedOn: Money.zero, brackets: ltcg);
      final stacked = applyStackedBrackets(Money.dollars(20000),
          stackedOn: Money.dollars(60000), brackets: ltcg);
      expect(stacked > free, isTrue);
    });
  });
}
