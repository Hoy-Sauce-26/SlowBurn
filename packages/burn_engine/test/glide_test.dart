import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

final taxYear =
    parseTaxYear(File('../../assets/tax_years/2026.json').readAsStringSync());

final classes = <Id, AssetClass>{
  for (final c in AssetClass.defaults) c.id: c,
};

Household saving({Id? retirementAllocation}) => Household(
      id: 'h1',
      taxUnits: [taxUnit()],
      people: [person(birthYear: 1985)],
      incomeStreams: [salary(pay: 150000)],
      accounts: [
        Account(
          id: 'brokerage',
          personId: 'p1',
          label: 'Brokerage',
          kind: AccountKind.taxableBrokerage,
          taxTreatment: TaxTreatment.taxable,
          limitFamily: LimitFamily.none,
          balance: Money.dollars(1500000),
          costBasis: Money.dollars(1000000),
          isRestrictedPurpose: false,
          assetAllocationId: 'usStocks',
          retirementAllocationId: retirementAllocation,
          contribution:
              const Contribution(mode: ContributionMode.fixedAmount, value: 0),
        ),
      ],
      expenseCategories: const [
        ExpenseCategory(
          id: 'cat',
          householdId: 'h1',
          label: 'Living',
          metaCategory: MetaCategory.misc,
        ),
      ],
      expenseItems: [
        ExpenseItem(
          id: 'exp',
          categoryId: 'cat',
          label: 'Everything',
          amount: Money.dollars(70000),
          frequency: ExpenseFrequency.annual,
        ),
      ],
    );

Projection run(Household h, {required int retirementYear}) => project(
      h,
      assumptions: const Assumptions(taxYearId: 'us-2026'),
      taxYear: taxYear,
      assetClasses: classes,
      band: BandName.expected,
      retirementYear: retirementYear,
      asOfDate: DateTime(2026, 6, 1),
    );

void main() {
  group('§3.9 what a portfolio is moved into at retirement', () {
    test('a plan that derisks ends with less than one that does not', () {
      // The point of the field. Stocks at 5% real carry a forty-year
      // retirement further than bonds at 2%, and a plan that intends to hold
      // bonds should be shown the bonds.
      final stayed = run(saving(), retirementYear: 2035);
      final derisked =
          run(saving(retirementAllocation: 'bonds'), retirementYear: 2035);

      final endStayed = stayed.years.last.netWorth.netWorth;
      final endDerisked = derisked.years.last.netWorth.netWorth;
      expect(endDerisked < endStayed, isTrue,
          reason: 'holding less in shares earns less, which is the trade');
    });

    test('and is identical until the year it retires', () {
      final stayed = run(saving(), retirementYear: 2035);
      final derisked =
          run(saving(retirementAllocation: 'bonds'), retirementYear: 2035);

      for (final year in [2026, 2030, 2034]) {
        final a = stayed.years.firstWhere((y) => y.year == year);
        final b = derisked.years.firstWhere((y) => y.year == year);
        expect(b.netWorth.netWorth, a.netWorth.netWorth,
            reason: 'nothing has moved yet in $year');
      }
    });

    test('leaving it null changes nothing at all', () {
      final a = run(saving(), retirementYear: 2035);
      final b = run(saving(retirementAllocation: null),
          retirementYear: 2035);
      expect(b.years.last.netWorth.netWorth, a.years.last.netWorth.netWorth);
    });

    test('the allocation in force follows the year', () {
      final account = saving(retirementAllocation: 'bonds').accounts.single;
      expect(account.allocationIn(retired: false), 'usStocks');
      expect(account.allocationIn(retired: true), 'bonds');
    });
  });
}
