import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

final taxYear =
    parseTaxYear(File('../../assets/tax_years/2026.json').readAsStringSync());

const year = 2026;

PersonWages wagesFor(Household h, {String personId = 'p1'}) => computeWages(
      h.personById(personId)!,
      household: h,
      taxYear: taxYear,
      year: year,
      currentYear: year,
    );

IncomeStream selfEmployment({num amount = 50000, String id = 'se-1'}) =>
    IncomeStream(
      id: id,
      personId: 'p1',
      label: 'Consulting',
      kind: IncomeKind.selfEmployment,
      grossAnnualAmount: Money.dollars(amount),
      isFicaSubject: false,
      isQualifiedBusinessIncome: true,
    );

void main() {
  group('§4.1 wages', () {
    test('kind places a stream for income tax, the flag only for FICA', () {
      // An `other` stream overridden to pay FICA must not also become wages.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [
          IncomeStream(
            id: 'inc-1',
            personId: 'p1',
            label: 'Odd job',
            kind: IncomeKind.other,
            grossAnnualAmount: Money.dollars(20000),
            isFicaSubject: true,
            isQualifiedBusinessIncome: false,
          ),
        ],
      );
      final w = wagesFor(h);
      expect(w.wageIncome, Money.zero, reason: 'kind is `other`');
      expect(w.ficaWages, Money.dollars(20000), reason: 'but the flag is set');
    });

    test('FICA wages floor at zero when cafeteria money exceeds pay', () {
      // Ordinary for a part-time job carrying family coverage. Unfloored, oasdi
      // and medicare would run negative.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 8000)],
        payrollDeductions: [
          const PayrollDeduction(
            id: 'pd1',
            personId: 'p1',
            label: 'Family premium',
            kind: PayrollDeductionKind.healthPremium,
            annualAmount: Money(1200000),
            reducesFicaWages: true,
          ),
        ],
      );
      final w = wagesFor(h);
      expect(w.ficaWages, Money.zero);
      expect(w.oasdi, Money.zero);
      expect(w.medicare, Money.zero);
    });
  });

  group('§4.2 payroll taxes', () {
    test('OASDI caps at the wage base and Medicare does not', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 400000)],
      );
      final w = wagesFor(h);
      expect(w.oasdi,
          taxYear.socialSecurityWageBase * taxYear.oasdiRate);
      expect(w.medicare, Money.dollars(400000) * taxYear.medicareRate);
    });

    test('the SE OASDI cap is shared with W-2 wages, per person', () {
      // §4.2's worked case: $150,000 of ficaWages and $50,000 of seEarnings.
      // A second independent cap would overtax a dual W-2-plus-side-income
      // earner, so only the base less the wages is left for the SE income.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 150000), selfEmployment(amount: 50000)],
      );
      final w = wagesFor(h);

      expect(w.ficaWages, Money.dollars(150000));
      expect(w.seNetEarnings,
          Money.dollars(50000) * taxYear.seNetEarningsFactor);

      final room = taxYear.socialSecurityWageBase - Money.dollars(150000);
      expect(w.seOasdi, room * taxYear.seOasdiRate,
          reason: 'only the room the wages left over');
      expect(w.seOasdi < w.seNetEarnings * taxYear.seOasdiRate, isTrue,
          reason: 'an independent cap would have charged more');

      // Medicare has no cap, so the SE half is charged on the whole figure.
      expect(w.seMedicare, w.seNetEarnings * taxYear.seMedicareRate);
    });

    test('wages past the base leave no OASDI room for side income', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 400000), selfEmployment(amount: 50000)],
      );
      expect(wagesFor(h).seOasdi, Money.zero);
    });

    test('self-employment income is not FICA-subject wages (§4.1)', () {
      // The default the doc names: were it true, SE income would pay OASDI
      // twice, once through ficaWages and again through seOasdi.
      expect(defaultIsFicaSubject(IncomeKind.selfEmployment), isFalse);
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [selfEmployment(amount: 50000)],
      );
      final w = wagesFor(h);
      expect(w.ficaWages, Money.zero);
      expect(w.oasdi, Money.zero);
    });

    test('the SE deduction is half of seTax and excludes additional Medicare',
        () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [selfEmployment(amount: 100000)],
      );
      final w = wagesFor(h);
      expect(w.seDeduction, w.seTax / 2);
    });
  });

  group('§4.2 additional Medicare, per TaxUnit', () {
    test('the threshold is a filing-status figure on combined income', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 250000), selfEmployment(amount: 50000)],
      );
      final w = wagesFor(h);
      final tax = additionalMedicare(
        [w],
        taxYear: taxYear,
        status: FilingStatus.single,
        year: year,
        currentYear: year,
        inflation: 0.025,
      );
      final threshold =
          taxYear.additionalMedicareThreshold[FilingStatus.single]!.value;
      expect(tax,
          (w.combinedMedicareWages - threshold) *
              taxYear.additionalMedicareRate);
      expect(tax.isPositive, isTrue);
    });

    test('below the threshold it is zero', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 90000)],
      );
      expect(
        additionalMedicare(
          [wagesFor(h)],
          taxYear: taxYear,
          status: FilingStatus.single,
          year: year,
          currentYear: year,
          inflation: 0.025,
        ),
        Money.zero,
      );
    });

    test('a fixed threshold deflates in later years (§7.4)', () {
      // The threshold has never been indexed, so a household that would not
      // cross it today crosses it in real terms two decades on.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 195000)],
      );
      final w = wagesFor(h);
      Money at(int y) => additionalMedicare(
            [w],
            taxYear: taxYear,
            status: FilingStatus.single,
            year: y,
            currentYear: year,
            inflation: 0.025,
          );
      expect(at(2026), Money.zero);
      expect(at(2046).isPositive, isTrue,
          reason: 'twenty years of deflation brings the threshold below pay');
    });
  });
}
