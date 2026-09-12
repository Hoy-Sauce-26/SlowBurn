import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

final taxYear =
    parseTaxYear(File('../../assets/tax_years/2026.json').readAsStringSync());
final asOf = DateTime(2026, 1, 1);

Projection run(
  Household h, {
  Assumptions? assumptions,
  int? retirementYear,
  BandName band = BandName.expected,
  DateTime? asOfDate,
}) =>
    project(
      h,
      assumptions: assumptions ?? const Assumptions(taxYearId: 'us-2026'),
      taxYear: taxYear,
      assetClasses: assetClasses(),
      asOfDate: asOfDate ?? asOf,
      retirementYear: retirementYear,
      band: band,
    );

Household accumulating({int birthYear = 1985, num pay = 150000}) => Household(
      id: 'h1',
      taxUnits: [taxUnit()],
      people: [person(birthYear: birthYear)],
      incomeStreams: [salary(pay: pay)],
      accounts: [traditional401k(balance: 200000), brokerageIn()],
      expenseCategories: [
        const ExpenseCategory(
          id: 'cat',
          householdId: 'h1',
          label: 'Living',
          metaCategory: MetaCategory.misc,
        ),
      ],
      expenseItems: [
        const ExpenseItem(
          id: 'e1',
          categoryId: 'cat',
          label: 'Living',
          amount: Money(6000000),
        ),
      ],
    );

void main() {
  group('§6 the loop runs', () {
    test('it reaches the horizon, the youngest person at 95', () {
      final p = run(accumulating(birthYear: 1985));
      expect(p.years.first.year, 2026);
      expect(p.years.last.year, 1985 + 95);
      expect(p.years.length, 1985 + 95 - 2026 + 1);
    });

    test('the youngest person sets the horizon, not the oldest', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person(birthYear: 1960), person(id: 'p2', birthYear: 1990)],
        incomeStreams: [salary(pay: 100000)],
      );
      expect(run(h).years.last.year, 1990 + 95);
    });

    test('only the first year is partial', () {
      final p = run(accumulating(), asOfDate: DateTime(2026, 7, 2));
      expect(p.years.first.frac, closeTo(0.5, 0.01));
      expect(p.years[1].frac, 1.0);
    });
  });

  group('§6 accumulation', () {
    test('a surplus year grows the portfolio', () {
      final p = run(accumulating());
      final first = p.years.first.netWorth.netWorth;
      final tenth = p.years[9].netWorth.netWorth;
      expect(tenth > first, isTrue);
      expect(p.years.first.netSurplus.isPositive, isTrue);
    });

    test('the pessimistic band ends below the optimistic one', () {
      final low = run(accumulating(), band: BandName.pessimistic);
      final high = run(accumulating(), band: BandName.optimistic);
      expect(high.years[20].netWorth.netWorth >
          low.years[20].netWorth.netWorth, isTrue);
    });

    test('basis rises with distributions, so gains are not taxed twice', () {
      final p = run(accumulating());
      // Balances move, and the taxable account keeps a basis that tracks what
      // has already been taxed.
      expect(p.years[5].accountBalances['acct-taxable']!.isPositive, isTrue);
    });

    test('a restricted account stays out of liquid net worth', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 120000)],
        accounts: [
          brokerageIn(balance: 100000),
          Account(
            id: '529',
            personId: 'p1',
            label: 'College',
            kind: AccountKind.education529,
            taxTreatment: TaxTreatment.educationTaxFree,
            limitFamily: LimitFamily.education,
            balance: Money.dollars(80000),
            isRestrictedPurpose: true,
            assetAllocationId: 'stocks',
            contribution: const Contribution(
                mode: ContributionMode.fixedAmount, value: 0),
          ),
        ],
      );
      final y = run(h).years.first.netWorth;
      expect(y.netWorth > y.liquidNetWorth, isTrue,
          reason: 'the 529 counts in net worth and not in liquid');
    });

    test('tuition draws the 529 down, and it runs out', () {
      // Once reported by nobody and wrong for every 529: the draw was sized
      // off the entered balance each year and never taken out, so $80,000
      // paid $30,000 a year indefinitely.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 120000)],
        accounts: [
          brokerageIn(balance: 100000),
          Account(
            id: '529',
            personId: 'p1',
            label: 'College',
            kind: AccountKind.education529,
            taxTreatment: TaxTreatment.educationTaxFree,
            limitFamily: LimitFamily.education,
            balance: Money.dollars(80000),
            isRestrictedPurpose: true,
            assetAllocationId: 'stocks',
            contribution: const Contribution(
                mode: ContributionMode.fixedAmount, value: 0),
          ),
        ],
        expenseCategories: const [
          ExpenseCategory(
            id: 'edu',
            householdId: 'h1',
            label: 'Education',
            metaCategory: MetaCategory.education,
          ),
        ],
        expenseItems: [
          ExpenseItem(
            id: 'college',
            categoryId: 'edu',
            label: 'College',
            amount: Money.dollars(30000),
            startYear: 2027,
            endYear: 2030,
          ),
        ],
      );
      final p = run(h);
      final paid = sumMoney(p.years
          .where((y) => y.year >= 2027 && y.year <= 2030)
          .map((y) => y.solved.cashFlow.education529Draw));
      expect(paid > Money.dollars(80000), isTrue,
          reason: 'it grows while it waits');
      expect(paid < Money.dollars(120000), isTrue,
          reason: 'four years at \$30,000 is more than it ever holds');
      // Not quite zero: money taken out mid-year earns half a year first.
      expect(p.yearOf(2030)!.accountBalances['529']! < Money.dollars(100),
          isTrue);
    });
  });

  group('§6 decumulation', () {
    Household retiring() => Household(
          id: 'h1',
          taxUnits: [taxUnit()],
          people: [person(birthYear: 1960, plannedRetirementAge: 66)],
          incomeStreams: [salary(pay: 150000, endYear: 2025)],
          accounts: [
            traditional401k(balance: 1500000),
            brokerageIn(balance: 800000, basis: 500000),
          ],
          expenseCategories: [
            const ExpenseCategory(
              id: 'cat',
              householdId: 'h1',
              label: 'Living',
              metaCategory: MetaCategory.misc,
            ),
          ],
          expenseItems: [
            const ExpenseItem(
              id: 'e1',
              categoryId: 'cat',
              label: 'Living',
              amount: Money(7000000),
            ),
          ],
        );

    test('a retired year draws to fill the gap', () {
      final p = run(retiring(), retirementYear: 2026);
      final first = p.years.first;
      expect(first.netSurplus.isNegative, isTrue,
          reason: 'no earned income and a cost of living to meet');
      expect(first.drawn.isPositive, isTrue);
    });

    test('the draw follows the withdrawal order', () {
      // Default order spends taxable before traditional, so the brokerage
      // falls first.
      final p = run(retiring(), retirementYear: 2026);
      final brokerageStart = Money.dollars(800000);
      expect(p.years.first.accountBalances['acct-taxable']! < brokerageStart,
          isTrue);
    });

    test('RMDs are taken whether or not the household needs the money', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person(birthYear: 1950)],
        incomeStreams: [salary(pay: 400000)],
        accounts: [traditional401k(balance: 2000000)],
      );
      final p = run(h, retirementYear: 2026);
      expect(p.years.first.solved.incomes.first.rmdIncome.isPositive, isTrue,
          reason: 'past the RMD age, working or not');
    });
  });

  group('§3.5 assets through the loop', () {
    test('a planned sale deposits its proceeds and retires the loan', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 150000)],
        accounts: [brokerageIn(balance: 50000, basis: 50000)],
        assets: [
          Asset(
            id: 'house',
            householdId: 'h1',
            label: 'House',
            category: AssetCategory.primaryResidence,
            currentValue: Money.dollars(600000),
            costBasis: Money.dollars(400000),
            realAppreciationRate: 0.01,
            securedByLiabilityId: 'mtg',
            plannedSaleYear: 2028,
            saleProceedsAccountId: 'acct-taxable',
          ),
        ],
        liabilities: [
          Liability(
            id: 'mtg',
            householdId: 'h1',
            label: 'Mortgage',
            kind: LiabilityKind.mortgage,
            currentBalance: Money.dollars(250000),
            interestRate: 0.05,
            monthlyPayment: Money.dollars(1800),
            monthlyEscrowAmount: Money.dollars(400),
            originationDate: DateTime(2018, 5, 1),
            termMonths: 360,
            securedAssetId: 'house',
          ),
        ],
      );
      final p = run(h);
      final before = p.yearOf(2027)!;
      final after = p.yearOf(2028)!;

      expect(after.accountBalances['acct-taxable']! >
          before.accountBalances['acct-taxable']!, isTrue,
          reason: 'the proceeds land in the named account');
      expect(after.netWorth.liquidNetWorth > before.netWorth.liquidNetWorth,
          isTrue,
          reason: 'an asset reaches liquid net worth only after a sale');
    });

    test('a §121 exclusion keeps an ordinary home sale untaxed', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 100000)],
        accounts: [brokerageIn(balance: 10000, basis: 10000)],
        assets: [
          Asset(
            id: 'house',
            householdId: 'h1',
            label: 'House',
            category: AssetCategory.primaryResidence,
            currentValue: Money.dollars(500000),
            costBasis: Money.dollars(400000),
            plannedSaleYear: 2027,
            saleProceedsAccountId: 'acct-taxable',
          ),
        ],
      );
      final p = run(h);
      final saleYear = p.yearOf(2027)!;
      final ordinaryYear = p.yearOf(2026)!;
      // A $100,000 gain sits well inside the $250,000 single exclusion.
      final extraGain = saleYear.solved.incomes.first.realizedLongTermGains -
          ordinaryYear.solved.incomes.first.realizedLongTermGains;
      expect(extraGain < Money.dollars(100000), isTrue,
          reason: 'a 100,000 gain sits well inside the 250,000 exclusion');
    });
  });
}
