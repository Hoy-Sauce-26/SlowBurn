import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

IncomeStream job({
  required String id,
  required num pay,
  int? startYear,
  int? endYear,
  int? startMonth,
  int? endMonth,
  Rate growth = 0,
}) =>
    IncomeStream(
      id: id,
      personId: 'p1',
      label: id,
      kind: IncomeKind.w2Wages,
      grossAnnualAmount: Money.dollars(pay),
      realGrowthRate: growth,
      startYear: startYear,
      endYear: endYear,
      startMonth: startMonth,
      endMonth: endMonth,
      isFicaSubject: true,
      isQualifiedBusinessIncome: false,
    );

void main() {
  group('activeFraction (§3.3)', () {
    test('a whole year is a whole year', () {
      expect(job(id: 'a', pay: 1000).activeFraction(2030), 1.0);
    });

    test('only the span its own first and last year are partial', () {
      final s = job(
        id: 'a',
        pay: 1200,
        startYear: 2030,
        startMonth: 4,
        endYear: 2032,
        endMonth: 9,
      );
      expect(s.activeFraction(2030), closeTo(9 / 12, 1e-12));
      expect(s.activeFraction(2031), 1.0, reason: 'a middle year is whole');
      expect(s.activeFraction(2032), closeTo(9 / 12, 1e-12));
    });

    test('a span opening and closing inside one year is trimmed at both ends',
        () {
      final s = job(
        id: 'a',
        pay: 1200,
        startYear: 2030,
        startMonth: 4,
        endYear: 2030,
        endMonth: 6,
      );
      expect(s.activeFraction(2030), closeTo(3 / 12, 1e-12),
          reason: 'April through June is three months');
    });

    test('a year outside the span contributes nothing', () {
      final s = job(id: 'a', pay: 1000, startYear: 2030, endYear: 2031);
      expect(s.activeFraction(2029), 0);
      expect(s.activeFraction(2032), 0);
    });
  });

  group('a mid-year job change (§3.3)', () {
    // The defect this rule exists for: without months, `endYear` and
    // `startYear` on the same year make both streams fully active and the
    // transition year carries two whole salaries.
    final leaving = job(
      id: 'old',
      pay: 150000,
      endYear: 2030,
      endMonth: 7,
    );
    final starting = job(
      id: 'new',
      pay: 170000,
      startYear: 2030,
      startMonth: 8,
    );

    test('the transition year carries the pay actually received', () {
      final total = leaving.resolvedAmount(2030, currentYear: 2030) +
          starting.resolvedAmount(2030, currentYear: 2030);
      expect(total.dollars, closeTo(150000 * 7 / 12 + 170000 * 5 / 12, 0.01));
      expect(total.dollars, lessThan(150000 + 170000));
    });

    test('the year after carries the new salary alone', () {
      expect(leaving.resolvedAmount(2031, currentYear: 2030), Money.zero);
      expect(starting.resolvedAmount(2031, currentYear: 2030),
          Money.dollars(170000));
    });
  });

  group('growth (§3.3)', () {
    test('compounds on the full-year rate, with proration applied after', () {
      final s = job(
        id: 'a',
        pay: 100000,
        growth: 0.02,
        startYear: 2030,
        startMonth: 7,
      );
      expect(s.resolvedAmount(2030, currentYear: 2030).dollars,
          closeTo(100000 * 6 / 12, 0.01));
      expect(s.resolvedAmount(2032, currentYear: 2030).dollars,
          closeTo(100000 * 1.02 * 1.02, 0.01));
    });

    test('a stream already running compounds from the current year', () {
      // Null startYear means the entered figure is this year's salary. Growing
      // from year zero instead would leave every existing salary flat.
      final s = job(id: 'a', pay: 100000, growth: 0.02);
      expect(s.resolvedAmount(2030, currentYear: 2030), Money.dollars(100000));
      expect(s.resolvedAmount(2031, currentYear: 2030), Money.dollars(102000));
    });
  });
}
