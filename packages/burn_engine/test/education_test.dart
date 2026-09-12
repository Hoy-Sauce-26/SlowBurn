import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

final taxYear =
    parseTaxYear(File('../../assets/tax_years/2026.json').readAsStringSync());
final classes = {for (final c in AssetClass.defaults) c.id: c};

Account college({
  String id = '529',
  String? child,
  num balance = 0,
  num perYear = 0,
  int? lastYearIn,
}) =>
    Account(
      id: id,
      personId: 'p1',
      label: 'College',
      kind: AccountKind.education529,
      taxTreatment: TaxTreatment.educationTaxFree,
      limitFamily: LimitFamily.education,
      balance: Money.dollars(balance),
      isRestrictedPurpose: true,
      assetAllocationId: 'usStocks',
      retirementAllocationId: 'bonds',
      beneficiaryId: child,
      contribution: Contribution(
        mode: ContributionMode.fixedAmount,
        value: Money.dollars(perYear).cents.toDouble(),
        endYear: lastYearIn,
      ),
    );

Household family({
  List<Account> accounts = const [],
  int from = 2036,
  int to = 2039,
  num tuition = 30000,
  String? forChild = 'k1',
}) =>
    Household(
      id: 'h1',
      taxUnits: [
        taxUnit(dependents: [
          Dependent(id: 'k1', name: 'Maya', birthDate: DateTime(2018, 3, 1)),
        ]),
      ],
      people: [person()],
      incomeStreams: [salary(pay: 150000)],
      accounts: [brokerageIn(balance: 100000), ...accounts],
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
            label: 'Living',
            amount: Money.dollars(60000)),
        ExpenseItem(
          id: 'college',
          categoryId: 'edu',
          label: "Maya's education",
          amount: Money.dollars(tuition),
          startYear: from,
          endYear: to,
          dependentId: forChild,
        ),
      ],
    );

Projection run(Household h) => project(h,
    assumptions: const Assumptions(taxYearId: 'us-2026'),
    taxYear: taxYear,
    assetClasses: classes,
    asOfDate: DateTime(2026, 1, 1),
    retirementYear: null);

void main() {
  group('§3.4 a 529 moves somewhere safer when its bills start', () {
    test('in its own child\'s first year of education, not at retirement', () {
      final h = family(accounts: [college(child: 'k1')]);
      final account = h.accounts.last;
      expect(h.firstTuitionYear(account), 2036);
      expect(h.movedIn(account, 2035, retirementYear: 2050), isFalse);
      expect(h.movedIn(account, 2036, retirementYear: 2050), isTrue);
    });

    test('and everything else still moves at retirement', () {
      final h = family();
      final brokerage = h.accounts.first;
      expect(h.movedIn(brokerage, 2036, retirementYear: 2050), isFalse);
      expect(h.movedIn(brokerage, 2050, retirementYear: 2050), isTrue);
    });

    test('so it earns less once the bills start', () {
      final h = family(accounts: [college(child: 'k1', balance: 200000)]);
      final p = run(h);
      Money balance(int year) => p.yearOf(year)!.accountBalances['529']!;
      final before = balance(2035).ratioTo(balance(2034));
      // Growth in 2037 is measured with that year's tuition added back.
      final after = (balance(2037) + Money.dollars(30000))
          .ratioTo(balance(2036));
      expect(after < before, isTrue);
    });
  });

  group('§4.4 a 529 with nothing left to pay for', () {
    test('is flagged once, the year after the last bill', () {
      final p = run(family(accounts: [college(child: 'k1', balance: 400000)]));
      final flagged = [
        for (final y in p.years)
          if (y.flags.contains('education529LeftOver')) y.year,
      ];
      expect(flagged, [2040]);
    });

    test('and not when it is spent', () {
      final p = run(family(accounts: [college(child: 'k1', balance: 60000)]));
      expect(p.years.any((y) => y.flags.contains('education529LeftOver')),
          isFalse);
    });
  });

  group('invariant 12 education names a child who is there', () {
    test('a line for a child who has gone is blocking', () {
      final findings = validateHousehold(family(forChild: 'gone'));
      expect(
          findings.any((f) =>
              f.severity == Severity.blocking && f.entityId == 'college'),
          isTrue);
    });

    test('and so is a 529 saving for one', () {
      final findings =
          validateHousehold(family(accounts: [college(child: 'gone')]));
      expect(
          findings
              .any((f) => f.severity == Severity.blocking && f.entityId == '529'),
          isTrue);
    });
  });
}
