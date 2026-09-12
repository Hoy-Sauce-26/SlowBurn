import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slow_burn/screens/accounts_screen.dart';
import 'package:slow_burn/screens/home_shell.dart';
import 'package:slow_burn/services/college.dart';
import 'package:slow_burn/services/providers.dart';
import 'package:slow_burn/services/readiness.dart';
import 'package:slow_burn/theme/app_theme.dart';

final taxYear =
    parseTaxYear(File('assets/tax_years/2026.json').readAsStringSync());
final thisYear = DateTime.now().year;

/// Somebody with one child and four years of college ten years out, funded
/// well enough to reach a retirement year. [born] and [collegeFrom] move the
/// child and their college, for one not born yet.
Household family({int? born, int? collegeFrom}) => Household(
      id: 'h1',
      taxUnits: [
        TaxUnit(
          id: 'tu1',
          householdId: 'h1',
          filingStatus: FilingStatus.single,
          stateCode: 'NY',
          dependents: [
            Dependent(
                id: 'k1',
                name: 'Maya',
                birthDate: DateTime(born ?? thisYear - 8)),
          ],
        ),
      ],
      people: [
        Person(
          id: 'p1',
          displayName: 'Alex',
          birthDate: DateTime(1985, 6, 15),
          taxUnitId: 'tu1',
        ),
      ],
      incomeStreams: [
        IncomeStream(
          id: 'pay',
          personId: 'p1',
          label: 'Pay',
          kind: IncomeKind.w2Wages,
          grossAnnualAmount: Money.dollars(200000),
          isFicaSubject: true,
          isQualifiedBusinessIncome: false,
        ),
      ],
      accounts: [
        Account(
          id: 'brokerage',
          personId: 'p1',
          label: 'Brokerage',
          kind: AccountKind.taxableBrokerage,
          taxTreatment: TaxTreatment.taxable,
          limitFamily: LimitFamily.none,
          balance: Money.dollars(1500000),
          costBasis: Money.dollars(1200000),
          isRestrictedPurpose: false,
          assetAllocationId: 'usStocks',
          contribution:
              const Contribution(mode: ContributionMode.fixedAmount, value: 0),
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
          label: 'Everything else',
          amount: Money.dollars(60000),
        ),
        ExpenseItem(
          id: 'college',
          categoryId: 'edu',
          label: "Maya's education",
          amount: Money.dollars(30000),
          startYear: collegeFrom ?? thisYear + 10,
          endYear: (collegeFrom ?? thisYear + 10) + 3,
          dependentId: 'k1',
        ),
      ],
    );

class _Fixed extends HouseholdNotifier {
  _Fixed(this._household);
  final Household _household;
  @override
  Household build() => _household;
}

class _Declared extends SetupProgressNotifier {
  @override
  SetupProgress build() => const SetupProgress(declaredReady: true);
}

Future<ProviderContainer> pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(overrides: [
    taxYearProvider.overrideWith((ref) => taxYear),
    setupProgressProvider.overrideWith(() => _Declared()),
    householdProvider.overrideWith(() => _Fixed(family())),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(theme: lightTheme(), home: const HomeShell()),
  ));
  await tester.pump();
  return container;
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a 529 sized to pay for all of it', () {
    test('does, near enough, when the engine runs it', () {
      final household = family();
      final plan = educationByChild(household).single;
      final draft = collegeDraft(household, plan, AssetClass.defaults,
          thisYear: thisYear);
      final p = project(
        household.copyWith(accounts: [...household.accounts, draft]),
        assumptions: const Assumptions(taxYearId: 'us-2026'),
        taxYear: taxYear,
        assetClasses: {for (final c in AssetClass.defaults) c.id: c},
        asOfDate: DateTime(thisYear, 1, 1),
        retirementYear: null,
      );

      final paid = sumMoney(p.years
          .where((y) => y.year >= thisYear + 10 && y.year <= thisYear + 13)
          .map((y) => y.solved.cashFlow.education529Draw));
      expect(paid.dollars, closeTo(120000, 6000),
          reason: 'four years of \$30,000, paid from the 529');
      expect(p.yearOf(thisYear + 14)!.accountBalances[draft.id]!.dollars,
          lessThan(6000),
          reason: 'and not much left over');
      expect(draft.contribution.endYear, thisYear + 9);
      expect(draft.contribution.startYear, isNull,
          reason: 'a child already here is saved for from now');
      expect(draft.retirementAllocationId, 'bonds');
    });

    test('for a child not born yet, starts the year they are', () {
      final born = thisYear + 2;
      final household = family(born: born, collegeFrom: born + 18);
      final plan = educationByChild(household).single;
      final draft = collegeDraft(household, plan, AssetClass.defaults,
          thisYear: thisYear);
      expect(draft.contribution.startYear, born);
      expect(draft.contribution.endYear, born + 17);

      final p = project(
        household.copyWith(accounts: [...household.accounts, draft]),
        assumptions: const Assumptions(taxYearId: 'us-2026'),
        taxYear: taxYear,
        assetClasses: {for (final c in AssetClass.defaults) c.id: c},
        asOfDate: DateTime(thisYear, 1, 1),
        retirementYear: null,
      );
      expect(p.yearOf(born - 1)!.accountBalances[draft.id], Money.zero,
          reason: 'nothing goes in before they arrive');
      final paid = sumMoney(p.years
          .where((y) => y.year >= born + 18 && y.year <= born + 21)
          .map((y) => y.solved.cashFlow.education529Draw));
      expect(paid.dollars, closeTo(120000, 6000),
          reason: 'and it still pays for all four years');
    });
  });

  group('the spending screen offers a 529 for each child', () {
    testWidgets('filled in, compared, and saved for that child',
        (tester) async {
      final container = await pumpApp(tester);
      await tester.tap(find.text('Spending').first);
      await tester.pumpAndSettle();

      expect(find.text('Maya'), findsOneWidget,
          reason: 'education is gathered under the child it is for');
      await tapVisible(tester, find.text('Save for this in a 529'));

      expect(find.textContaining("Paying for all of Maya's education"),
          findsOneWidget);

      await tapVisible(tester, find.text('Compare'));
      expect(find.text('You can retire'), findsOneWidget);
      expect(find.text('Tax over the plan'), findsOneWidget);

      await tapVisible(tester, find.text('Save').last);

      final saved = container
          .read(householdProvider)
          .accounts
          .where((a) => a.kind == AccountKind.education529)
          .single;
      expect(saved.beneficiaryId, 'k1');
      expect(saved.label, "Maya's 529");
      expect(saved.contribution.value, greaterThan(0));
      expect(saved.contribution.endYear, thisYear + 9);
      expect(find.text("Open Maya's 529"), findsOneWidget);
    });
  });
}
