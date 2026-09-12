import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

final taxYear =
    parseTaxYear(File('../../assets/tax_years/2026.json').readAsStringSync());
final classes = {for (final c in AssetClass.defaults) c.id: c};

Household plan({
  required int pay,
  required num balance,
  bool withCollege = false,
  bool with529 = false,
}) =>
    Household(
      id: 'h1',
      taxUnits: [taxUnit()],
      people: [person(birthYear: 1985)],
      incomeStreams: [salary(pay: pay)],
      accounts: [
        brokerageIn(balance: balance, basis: balance * 0.7),
        if (with529)
          Account(
            id: '529',
            personId: 'p1',
            label: 'College',
            kind: AccountKind.education529,
            taxTreatment: TaxTreatment.educationTaxFree,
            limitFamily: LimitFamily.education,
            balance: Money.dollars(200000),
            isRestrictedPurpose: true,
            assetAllocationId: 'usStocks',
            contribution: const Contribution(
                mode: ContributionMode.fixedAmount, value: 0),
          ),
      ],
      expenseCategories: const [
        ExpenseCategory(
            id: 'misc',
            householdId: 'h1',
            label: 'Living',
            metaCategory: MetaCategory.misc),
        ExpenseCategory(
            id: 'edu',
            householdId: 'h1',
            label: 'Education',
            metaCategory: MetaCategory.education),
      ],
      expenseItems: [
        ExpenseItem(
          id: 'living',
          categoryId: 'misc',
          label: 'Everything',
          amount: Money.dollars(70000),
          frequency: ExpenseFrequency.annual,
        ),
        if (withCollege)
          ExpenseItem(
            id: 'college',
            categoryId: 'edu',
            label: 'College',
            amount: Money.dollars(50000),
            frequency: ExpenseFrequency.annual,
            startYear: 2044,
            endYear: 2046,
          ),
      ],
    );

BandResult solve(Household h) => solveAllBands(h,
        assumptions: const Assumptions(taxYearId: 'us-2026'),
        taxYear: taxYear,
        assetClasses: classes,
        asOfDate: DateTime(2026, 6, 1))
    .expected;

void main() {
  group('§8.1 a cost that ends before retirement', () {
    test('moves the date and not the target', () {
      // Reported as a broken calculator: $150,000 of college added and the
      // FIRE number did not move. It should not. The target is what
      // retirement costs, and college is over before it starts.
      final without = solve(plan(pay: 160000, balance: 700000));
      final with_ = solve(
          plan(pay: 160000, balance: 700000, withCollege: true));

      expect(without.retirementYear, isNotNull);
      expect(with_.retirementYear! > without.retirementYear!, isTrue,
          reason: 'the money has to come from somewhere, so it comes from '
              'the date');
      expect(with_.fireNumber, without.fireNumber,
          reason: 'the years being funded are identical in both');
    });

    test('and one that lands inside retirement moves both', () {
      final without = solve(plan(pay: 250000, balance: 2200000));
      final with_ = solve(
          plan(pay: 250000, balance: 2200000, withCollege: true));

      expect(without.retirementYear! < 2044, isTrue,
          reason: 'this household is retired before the college years');
      expect(with_.fireNumber!.cents > without.fireNumber!.cents, isTrue,
          reason: 'now it is part of what retirement costs');
    });

    test('unless a 529 pays for it', () {
      // The 529 sits outside the money retirement is measured on, so the
      // tuition it pays cannot be in the target too. Counted in both, opening
      // a 529 made retiring later.
      final without = solve(plan(pay: 250000, balance: 2200000));
      final with_ = solve(plan(
          pay: 250000, balance: 2200000, withCollege: true, with529: true));

      expect(with_.retirementYear, without.retirementYear);
      expect(with_.fireNumber, without.fireNumber);
    });
  });

  group('§5 supply and demand are not the same number', () {
    // Reported as: "if I spend 100k extra in retirement, the amount I need in
    // that retirement should increase". It should, and the demand-side figure
    // is the one that says so. `sustainableLevelSpending` is the supply side,
    // assets times the withdrawal rate, and reads as unmoved.
    Household spending({required bool extra}) => Household(
          id: 'h1',
          taxUnits: [taxUnit()],
          people: [person(birthYear: 1985)],
          incomeStreams: [salary(pay: 250000)],
          accounts: [brokerageIn(balance: 2200000, basis: 1500000)],
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
            if (extra)
              ExpenseItem(
                id: 'splurge',
                categoryId: 'misc',
                label: 'Three big years',
                amount: Money.dollars(100000),
                frequency: ExpenseFrequency.annual,
                startYear: 2044,
                endYear: 2046,
              ),
          ],
        );

    test('spending more inside retirement raises what retirement costs', () {
      final plain = solve(spending(extra: false));
      final more = solve(spending(extra: true));

      expect(plain.retirementYear! <= 2044, isTrue,
          reason: 'the extra spending has to land inside retirement');
      expect(
          more.levelEquivalentRetirementExpenses!.cents >
              plain.levelEquivalentRetirementExpenses!.cents,
          isTrue);
      expect(more.fireNumber!.cents > plain.fireNumber!.cents, isTrue);
    });

    test('and the supply-side figure is not the one that shows it', () {
      // Kept as a test rather than a comment: it is the mistake that made the
      // breakdown look broken, and it would be easy to make again.
      final plain = solve(spending(extra: false));
      final more = solve(spending(extra: true));

      final demandMoved = more.levelEquivalentRetirementExpenses!.cents -
          plain.levelEquivalentRetirementExpenses!.cents;
      final supplyMoved = (more.sustainableLevelSpending!.cents -
              plain.sustainableLevelSpending!.cents)
          .abs();
      expect(demandMoved > supplyMoved, isTrue,
          reason: 'what retirement costs is what moves when spending moves');
    });

    test('the two answer opposite questions at the same year', () {
      final r = solve(spending(extra: false));
      expect(r.spendingHeadroom,
          r.sustainableLevelSpending! - r.levelEquivalentRetirementExpenses!,
          reason: '§5: headroom is supply less demand');
    });
  });
}
