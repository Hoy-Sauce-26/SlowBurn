import 'dart:io';
import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';
import 'fixtures/households.dart';

final taxYear =
    parseTaxYear(File('../../assets/tax_years/2026.json').readAsStringSync());

void main() {
  test('house sold 2046, rent from 2046', () {
    final h = Household(
      id: 'h1',
      taxUnits: [taxUnit()],
      people: [person(birthYear: 1992)],
      incomeStreams: [salary(pay: 150000)],
      assets: [
        Asset(
          id: 'house',
          householdId: 'h1',
          label: 'House',
          category: AssetCategory.primaryResidence,
          currentValue: Money.dollars(600000),
          costBasis: Money.dollars(450000),
          plannedSaleYear: 2046,
          saleProceedsAccountId: 'acct-taxable',
        ),
      ],
      accounts: [brokerageIn()],
      expenseCategories: const [
        ExpenseCategory(
            id: 'housing',
            householdId: 'h1',
            label: 'Housing',
            metaCategory: MetaCategory.housing),
        ExpenseCategory(
            id: 'misc',
            householdId: 'h1',
            label: 'Living',
            metaCategory: MetaCategory.misc),
      ],
      expenseItems: [
        ExpenseItem(
          id: 'rent',
          categoryId: 'housing',
          label: 'Rent',
          amount: Money.dollars(30000),
          frequency: ExpenseFrequency.annual,
          startYear: 2046,
        ),
        ExpenseItem(
          id: 'living',
          categoryId: 'misc',
          label: 'Everything',
          amount: Money.dollars(60000),
          frequency: ExpenseFrequency.annual,
        ),
      ],
    );

    final spans = housingTimeline(h, fromYear: 2026, toYear: 2087);
    for (final s in spans) {
      print('${s.fromYear}-${s.toYear} gap=${s.isGap} '
          'covers=${s.covers.map((c) => c.label).join(",")}');
    }

    final r = project(h,
        assumptions: const Assumptions(taxYearId: 'us-2026'),
        taxYear: taxYear,
        assetClasses: {for (final c in AssetClass.defaults) c.id: c},
        band: BandName.expected,
        retirementYear: 2050,
        asOfDate: DateTime(2026, 6, 1));
    final bad = r.years.where((y) => y.flags.contains('noHousingCost'));
    print('FLAGGED YEARS: ${bad.map((y) => y.year).take(8).toList()}');
  });
}
