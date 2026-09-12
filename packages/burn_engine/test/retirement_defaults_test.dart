import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

final taxYear =
    parseTaxYear(File('../../assets/tax_years/2026.json').readAsStringSync());
final classes = {for (final c in AssetClass.defaults) c.id: c};

Household working({IncomeKind kind = IncomeKind.w2Wages}) => Household(
      id: 'h1',
      taxUnits: [taxUnit()],
      people: [person(birthYear: 1985)],
      incomeStreams: [
        IncomeStream(
          id: 'inc',
          personId: 'p1',
          label: 'Pay',
          kind: kind,
          grossAnnualAmount: Money.dollars(150000),
          isFicaSubject: kind.isEarned,
          isQualifiedBusinessIncome: false,
        ),
      ],
      accounts: [brokerageIn(balance: 2000000, basis: 1500000)],
      expenseCategories: const [
        ExpenseCategory(
            id: 'misc',
            householdId: 'h1',
            label: 'Living',
            metaCategory: MetaCategory.misc),
      ],
      expenseItems: [
        ExpenseItem(
          id: 'living',
          categoryId: 'misc',
          label: 'Everything',
          amount: Money.dollars(70000),
          frequency: ExpenseFrequency.annual,
        ),
      ],
    );

void main() {
  group('§3.3 earned income stops at retirement', () {
    test('a salary with no end year ends the year before', () {
      // The defect this exists for: `endYear` "defaults to the year before
      // retirement", and a default nothing resolves is a salary paid to 95.
      final resolved = withRetirementDefaults(working(), 2040);
      expect(resolved.incomeStreams.single.endYear, 2039);
    });

    test('a pension keeps going, being unearned', () {
      final resolved =
          withRetirementDefaults(working(kind: IncomeKind.pension), 2040);
      expect(resolved.incomeStreams.single.endYear, isNull);
    });

    test('an end year somebody entered is left alone', () {
      final h = working();
      final barista = h.copyWith(incomeStreams: [
        IncomeStream(
          id: 'inc',
          personId: 'p1',
          label: 'Barista job',
          kind: IncomeKind.w2Wages,
          grossAnnualAmount: Money.dollars(20000),
          endYear: 2050,
          isFicaSubject: true,
          isQualifiedBusinessIncome: false,
        ),
      ]);
      expect(withRetirementDefaults(barista, 2040).incomeStreams.single.endYear,
          2050,
          reason: '§9.2: a Barista FIRE job runs past retirement on purpose');
    });

    test('nothing moves before a retirement year is solved', () {
      expect(withRetirementDefaults(working(), null).incomeStreams.single.endYear,
          isNull);
    });

    test('payroll deferrals and deductions stop with the pay', () {
      final h = working().copyWith(
        payrollDeductions: [
          const PayrollDeduction(
            id: 'fsa',
            personId: 'p1',
            label: 'FSA',
            kind: PayrollDeductionKind.healthFsa,
            annualAmount: Money.zero,
            reducesFederalTaxableIncome: true,
            reducesStateTaxableIncome: true,
            reducesFicaWages: true,
          ),
        ],
      );
      final resolved = withRetirementDefaults(h, 2040);
      expect(resolved.payrollDeductions.single.endYear, 2039);
      expect(resolved.accounts.single.contribution.endYear, 2039);
    });

    test('the projection stops paying it, which is the whole point', () {
      final r = project(working(),
          assumptions: const Assumptions(taxYearId: 'us-2026'),
          taxYear: taxYear,
          assetClasses: classes,
          band: BandName.expected,
          retirementYear: 2040,
          asOfDate: DateTime(2026, 6, 1));

      final before = r.years.firstWhere((y) => y.year == 2039);
      final after = r.years.firstWhere((y) => y.year == 2041);
      expect(before.solved.cashFlow.grossIncome.isPositive, isTrue);
      expect(after.solved.cashFlow.grossIncome, Money.zero,
          reason: 'retired means retired');
    });

    test('and net worth turns over instead of climbing forever', () {
      // Every band rising to the horizon was the symptom: a household that
      // never stops earning never draws on its portfolio.
      final r = project(working(),
          assumptions: const Assumptions(taxYearId: 'us-2026'),
          taxYear: taxYear,
          assetClasses: classes,
          band: BandName.pessimistic,
          retirementYear: 2040,
          asOfDate: DateTime(2026, 6, 1));

      final atRetirement =
          r.years.firstWhere((y) => y.year == 2040).netWorth.netWorth;
      final atEnd = r.years.last.netWorth.netWorth;
      expect(atEnd.cents < atRetirement.cents, isTrue,
          reason: 'drawing down at a pessimistic return has to cost something');
    });
  });
}
