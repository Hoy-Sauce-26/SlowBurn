import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slow_burn/screens/home_shell.dart';
import 'package:slow_burn/services/providers.dart';
import 'package:slow_burn/services/readiness.dart';
import 'package:slow_burn/theme/app_theme.dart';
import 'package:slow_burn/widgets/fields.dart';
import 'package:slow_burn/widgets/net_worth_chart.dart';

final taxYear =
    parseTaxYear(File('assets/tax_years/2026.json').readAsStringSync());

/// The smallest household that is allowed past the setup gate: somebody, and
/// what a year costs them.
Household readyHousehold() => Household(
      id: 'h1',
      taxUnits: [
        const TaxUnit(
          id: 'tu1',
          householdId: 'h1',
          filingStatus: FilingStatus.single,
          stateCode: 'CO',
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
      // Funded enough to reach a retirement year, which is what the
      // withdrawal-rate advice reads.
      accounts: [
        Account(
          id: 'brokerage',
          personId: 'p1',
          label: 'Brokerage',
          kind: AccountKind.taxableBrokerage,
          taxTreatment: TaxTreatment.taxable,
          limitFamily: LimitFamily.none,
          balance: Money.dollars(3000000),
          costBasis: Money.dollars(2500000),
          isRestrictedPurpose: false,
          assetAllocationId: 'usStocks',
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
          label: 'Everything else',
          amount: Money.dollars(60000),
          frequency: ExpenseFrequency.annual,
        ),
      ],
    );

class _Fixed extends HouseholdNotifier {
  _Fixed(this._household);
  final Household _household;
  @override
  Household build() => _household;
}

Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  Size size = const Size(1600, 1200),
  bool ready = false,
  Household? household,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      taxYearProvider.overrideWith((ref) => taxYear),
      if (ready) ...[
        setupProgressProvider.overrideWith(() => _Declared()),
        householdProvider
            .overrideWith(() => _Fixed(household ?? readyHousehold())),
      ],
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: lightTheme(), home: const HomeShell()),
    ),
  );
  await tester.pump();
  // The app opens on Plan. These tests are about the other six screens, so
  // they start from the first of them.
  await tapRail(tester, 'Household');
  return container;
}

/// A `DropdownMenu` keeps every entry in the tree whether open or not, so the
/// one to tap is whichever the overlay put on top.
/// The dropdown carrying a given label. `find.byType` cannot be used, since
/// these are `DropdownMenu<int?>` and friends rather than the raw type.
Finder dropdown(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((w) => w is DropdownMenu),
    );

Future<void> pick(WidgetTester tester, String field, String value) async {
  // A field only half on screen takes a tap that lands somewhere else, and
  // since the editor stopped closing on a stray click that shows up as a menu
  // that never opened.
  final menu = dropdown(field).first;
  await tester.ensureVisible(menu);
  await tester.pumpAndSettle();
  await tester.tap(menu);
  await tester.pumpAndSettle();

  // Every entry stays mounted whether its menu is open or not, so the one to
  // tap is whichever is really on top. Where the open list has scrolled past
  // it, typing narrows the list until it is there, which is what a person
  // would do anyway.
  var item = find.widgetWithText(MenuItemButton, value).hitTestable();
  if (item.evaluate().isEmpty) {
    await tester.enterText(
        find.descendant(of: menu, matching: find.byType(TextField)), value);
    await tester.pumpAndSettle();
    item = find.widgetWithText(MenuItemButton, value).hitTestable();
  }
  await tester.tap(item.last);
  await tester.pumpAndSettle();
}



Future<void> tapRail(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).first);
  await tester.pump();
}

/// Somebody who has already been through setup and asked to see numbers.
class _Declared extends SetupProgressNotifier {
  @override
  SetupProgress build() => const SetupProgress(declaredReady: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the screens are reachable and say what they are for', () {
    testWidgets('each destination opens its own screen', (tester) async {
      await pumpApp(tester);
      for (final (label, heading) in [
        ('Income', 'Income'),
        ('Accounts', 'Accounts'),
        ('Spending', 'Spending'),
        ('Property', 'Property and debts'),
        ('Plan', 'Plan'),
      ]) {
        await tapRail(tester, label);
        expect(find.text(heading), findsWidgets, reason: 'after tapping $label');
      }
    });

    testWidgets('an empty screen explains rather than sitting blank',
        (tester) async {
      await pumpApp(tester);
      expect(find.textContaining('Start with yourself'), findsOneWidget);
    });

    testWidgets('income cannot be added before there is a person to own it',
        (tester) async {
      await pumpApp(tester);
      await tapRail(tester, 'Income');
      expect(find.text('Add income'), findsNothing);
      expect(find.textContaining('Add a person on the Household screen'),
          findsOneWidget,
          reason: 'the wage base and every limit are per individual');
    });
  });

  group('adding a person', () {
    testWidgets('creates a tax unit alongside, since one needs the other',
        (tester) async {
      final container = await pumpApp(tester);
      await tester.tap(find.text('Add a person'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Name'), 'Alex');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final household = container.read(householdProvider);
      expect(household.people, hasLength(1));
      expect(household.people.single.displayName, 'Alex');
      expect(household.taxUnits, hasLength(1),
          reason: 'a person with no return would trip invariant 3 at once');
      expect(household.people.single.taxUnitId, household.taxUnits.single.id);
      expect(validateHousehold(household), isEmpty);
    });

    testWidgets('unlocks the screens that need someone to own things',
        (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('Add a person'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Name'), 'Alex');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      await tapRail(tester, 'Income');
      expect(find.text('Add income'), findsOneWidget);
    });
  });

  group('the plan screen edits assumptions', () {
    testWidgets('changing the withdrawal rate reaches the scenario',
        (tester) async {
      final container = await pumpApp(tester, ready: true);
      await tapRail(tester, 'Plan');

      final field = find.widgetWithText(TextFormField, 'Safe withdrawal rate');
      await tester.scrollUntilVisible(field, 200,
          scrollable: find.byType(Scrollable).first);
      expect(field, findsOneWidget, reason: '4% is the default');
      await tester.enterText(field, '3.5');
      await tester.pump();

      expect(container.read(scenarioProvider).assumptions.safeWithdrawalRate,
          closeTo(0.035, 1e-9));
    });

    testWidgets('Social Security can be switched off entirely', (tester) async {
      final container = await pumpApp(tester, ready: true);
      await tapRail(tester, 'Plan');
      // The plan screen now carries a chart and the return assumptions, so
      // the switch is below the fold.
      await tester.scrollUntilVisible(
          find.text('Count on Social Security'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Count on Social Security'));
      await tester.pump();
      expect(container.read(scenarioProvider).assumptions.includeSocialSecurity,
          isFalse);
    });
  });

  group('the plan screen shows the levers, not just the answer', () {
    testWidgets('net worth is drawn across all three bands', (tester) async {
      await pumpApp(tester, ready: true);
      await tapRail(tester, 'Plan');
      expect(find.byType(NetWorthChart), findsOneWidget);
      expect(find.text('Optimistic'), findsWidgets);
      expect(find.text('Pessimistic'), findsWidgets);
    });

    testWidgets('what each holding earns can be read and changed',
        (tester) async {
      final container = await pumpApp(tester, ready: true);
      await tapRail(tester, 'Plan');
      await tester.scrollUntilVisible(
          find.text('What each holding earns'), 300,
          scrollable: find.byType(Scrollable).first);

      expect(find.text('US stocks'), findsWidgets);
      expect(find.text('Savings interest'), findsWidgets);

      final field = find.descendant(
        of: find.ancestor(
            of: find.text('US stocks'), matching: find.byType(Card)),
        matching: find.widgetWithText(TextFormField, 'Expected'),
      );
      await tester.enterText(field, '4');
      await tester.pump();

      final stocks = container
          .read(assetClassesProvider)
          .firstWhere((c) => c.label == AssetClassLabel.usStocks);
      expect(stocks.expectedRealReturn, closeTo(0.04, 1e-9));
    });

    testWidgets('what property does is an assumption, not a per-asset guess',
        (tester) async {
      final container = await pumpApp(tester, ready: true);
      await tapRail(tester, 'Plan');
      await tester.scrollUntilVisible(find.text('What property does'), 300,
          scrollable: find.byType(Scrollable).first);

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Vehicle'), '-8');
      await tester.pump();
      expect(
          container.read(scenarioProvider).assumptions
              .assetAppreciationByCategory[AssetCategory.vehicle],
          closeTo(-0.08, 1e-9));
    });
  });

  group('the breakdown asks three questions in order', () {
    testWidgets('and answers each of them', (tester) async {
      await pumpApp(tester, ready: true);
      await tapRail(tester, 'Breakdown');

      expect(find.text('What will I be spending in retirement?'),
          findsOneWidget);
      expect(find.text('What do I need to own to pay for that?'),
          findsOneWidget);
      await tester.scrollUntilVisible(
          find.text('How long until I own it?'), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('How long until I own it?'), findsOneWidget);

      await tester.scrollUntilVisible(
          find.text('What will I be spending in retirement?'), -300,
          scrollable: find.byType(Scrollable).first);
      final one =
          tester.getTopLeft(find.text('What will I be spending in retirement?'));
      final two =
          tester.getTopLeft(find.text('What do I need to own to pay for that?'));
      expect(one.dy, lessThan(two.dy));
    });

    testWidgets('the three ways of asking it are shown with their rates',
        (tester) async {
      // Two of them differ only by rate and two only by shape, which is the
      // only way the ordering reads as sensible.
      await pumpApp(tester, ready: true);
      await tapRail(tester, 'Breakdown');
      await tester.scrollUntilVisible(
          find.text('Three ways of asking it'), 200,
          scrollable: find.byType(Scrollable).first);

      expect(find.text('Never spend the capital'), findsNWidgets(2));
      expect(find.textContaining('Spend it to zero over'), findsOneWidget);
      expect(find.textContaining('your withdrawal rate · the figure above'),
          findsOneWidget);
      expect(find.textContaining('what you will hold'), findsNWidgets(2));
    });

    testWidgets('the retirement holding is set where its rate is used',
        (tester) async {
      final container = await pumpApp(tester, ready: true);
      await tapRail(tester, 'Breakdown');
      // A dropdown renders its label twice, so this scrolls to the first.
      await tester.scrollUntilVisible(
          find.text('What you move into at retirement').first, 200,
          scrollable: find.byType(Scrollable).first);

      await pick(tester, 'What you move into at retirement', 'Bonds');
      for (final a in container
          .read(householdProvider)
          .accounts
          .where((a) => !a.kind.isCash)) {
        expect(a.retirementAllocationId, 'bonds');
      }
    });

    testWidgets('says which rate each figure uses and what none of them count',
        (tester) async {
      // Asked: why does the headline differ from the drawdown figure, is it
      // Social Security? It is the rate and the shape, and none of the three
      // count Social Security at all.
      await pumpApp(tester, ready: true);
      await tapRail(tester, 'Breakdown');
      await tester.scrollUntilVisible(
          find.textContaining('None of the three counts Social Security'),
          200,
          scrollable: find.byType(Scrollable).first);

      expect(find.textContaining('None of the three counts Social Security'),
          findsOneWidget);
      expect(find.textContaining('A lower rate needs more'), findsOneWidget);
    });

    testWidgets('a rate changed here reaches the scenario', (tester) async {
      final container = await pumpApp(tester, ready: true);
      await tapRail(tester, 'Breakdown');
      final field = find.widgetWithText(TextFormField, 'Safe withdrawal rate');
      await tester.scrollUntilVisible(field, 200,
          scrollable: find.byType(Scrollable).first);

      await tester.enterText(field, '3.25');
      await tester.pump();
      expect(
          container.read(scenarioProvider).assumptions.safeWithdrawalRate,
          closeTo(0.0325, 1e-9));
    });

    testWidgets('the health premium is shown rather than left to be guessed',
        (tester) async {
      // It is computed from income and household size, and adding it as a
      // spending line would count it twice.
      final early = readyHousehold().copyWith(
        people: [
          Person(
            id: 'p1',
            displayName: 'Alex',
            birthDate: DateTime(1985, 6, 15),
            taxUnitId: 'tu1',
            employerHealthCoverageEndYear: DateTime.now().year - 1,
          ),
        ],
      );
      await pumpApp(tester, ready: true, household: early);
      await tapRail(tester, 'Breakdown');

      expect(
          find.text('Health coverage, which the plan works out for itself'),
          findsOneWidget);
      expect(find.textContaining('counted twice'), findsOneWidget);
    });

    testWidgets('spending more in retirement raises what it says you need',
        (tester) async {
      // The report: adding \$100,000 a year of retirement spending left the
      // drawdown figure unmoved, because it was built on what the pot
      // supports rather than on what retirement costs.
      Household withExtra(bool extra) => readyHousehold().copyWith(
            expenseItems: [
              ...readyHousehold().expenseItems,
              if (extra)
                ExpenseItem(
                  id: 'splurge',
                  categoryId: 'cat',
                  label: 'Three big years',
                  amount: Money.dollars(100000),
                  frequency: ExpenseFrequency.annual,
                  startYear: DateTime.now().year + 18,
                  endYear: DateTime.now().year + 20,
                ),
            ],
          );

      Money need(ProviderContainer c) =>
          c.read(projectionProvider).requireValue.expected.fireNumber!;
      Money cost(ProviderContainer c) => c
          .read(projectionProvider)
          .requireValue
          .expected
          .levelEquivalentRetirementExpenses!;

      final plain = await pumpApp(tester, ready: true,
          household: withExtra(false));
      final plainNeed = need(plain);
      final plainCost = cost(plain);

      final more =
          await pumpApp(tester, ready: true, household: withExtra(true));
      expect(cost(more).cents, greaterThan(plainCost.cents));
      expect(need(more).cents, greaterThan(plainNeed.cents));
    });

    testWidgets('spending that ends before retirement is called out',
        (tester) async {
      // Otherwise adding college looks like the calculator ignoring it.
      // Retiring well after the college years, which is the case where the
      // target legitimately does not move.
      final h = readyHousehold().copyWith(
        accounts: [
          Account(
            id: 'brokerage',
            personId: 'p1',
            label: 'Brokerage',
            kind: AccountKind.taxableBrokerage,
            taxTreatment: TaxTreatment.taxable,
            limitFamily: LimitFamily.none,
            balance: Money.dollars(700000),
            costBasis: Money.dollars(500000),
            isRestrictedPurpose: false,
            assetAllocationId: 'usStocks',
            contribution: const Contribution(
                mode: ContributionMode.fixedAmount, value: 0),
          ),
        ],
        incomeStreams: [
          IncomeStream(
            id: 'inc',
            personId: 'p1',
            label: 'Salary',
            kind: IncomeKind.w2Wages,
            grossAnnualAmount: Money.dollars(160000),
            isFicaSubject: true,
            isQualifiedBusinessIncome: false,
          ),
        ],
      );
      final withCollege = h.copyWith(
        expenseCategories: [
          ...h.expenseCategories,
          const ExpenseCategory(
              id: 'edu',
              householdId: 'h1',
              label: 'Education',
              metaCategory: MetaCategory.education),
        ],
        expenseItems: [
          ...h.expenseItems,
          ExpenseItem(
            id: 'college',
            categoryId: 'edu',
            label: 'College',
            amount: Money.dollars(50000),
            frequency: ExpenseFrequency.annual,
            startYear: DateTime.now().year + 2,
            endYear: DateTime.now().year + 4,
          ),
        ],
      );
      await pumpApp(tester, ready: true, household: withCollege);
      await tapRail(tester, 'Breakdown');

      expect(find.text('Spending that ends before you retire'), findsOneWidget);
      expect(find.textContaining('moves the date in question three'),
          findsOneWidget);
    });

    testWidgets('a plan with nothing entered says so rather than guessing',
        (tester) async {
      await pumpApp(tester);
      await tapRail(tester, 'Breakdown');
      expect(find.textContaining('not enough entered yet'), findsWidgets);
    });
  });

  group('the withdrawal rate explains itself', () {
    testWidgets('it says how long the money has to last', (tester) async {
      await pumpApp(tester, ready: true);
      await tapRail(tester, 'Plan');
      await tester.scrollUntilVisible(
          find.textContaining('the money has to last'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('the money has to last'), findsOneWidget);
    });

    testWidgets('and offers the rate that suits it', (tester) async {
      final container = await pumpApp(tester, ready: true);
      await tapRail(tester, 'Plan');

      await tester.scrollUntilVisible(
          find.textContaining('the money has to last'), 200,
          scrollable: find.byType(Scrollable).first);
      final offer = find.byWidgetPredicate((w) =>
          w is FilledButton &&
          w.child is Text &&
          (w.child! as Text).data!.startsWith('Use '));
      if (offer.evaluate().isEmpty) {
        // Already on the suggested rate, which is the other valid outcome.
        expect(find.textContaining('which is what you have'), findsOneWidget);
        return;
      }

      await tester.ensureVisible(offer);
      await tester.pumpAndSettle();
      await tester.tap(offer);
      await tester.pumpAndSettle();

      final rate = container.read(scenarioProvider).assumptions
          .safeWithdrawalRate;
      final retires = container
          .read(projectionProvider)
          .requireValue
          .expected
          .retirementYear!;
      final end = horizonYear(container.read(householdProvider),
          container.read(scenarioProvider).assumptions, DateTime.now().year);
      expect(rate, suggestedWithdrawalRate(end - retires + 1));
    });

    testWidgets('taking the offer does not then flag the rate',
        (tester) async {
      // The whole point of one shared ladder.
      final container = await pumpApp(tester, ready: true);
      await tapRail(tester, 'Plan');
      final retires = container
          .read(projectionProvider)
          .requireValue
          .expected
          .retirementYear!;
      final end = horizonYear(container.read(householdProvider),
          container.read(scenarioProvider).assumptions, DateTime.now().year);
      final years = end - retires + 1;

      expect(
          swrHorizonMismatch(
              Assumptions(
                  taxYearId: 'us-2026',
                  safeWithdrawalRate: suggestedWithdrawalRate(years)),
              years),
          isFalse);
    });
  });

  group('what you hold once retired', () {
    testWidgets('is set once for the whole plan, not account by account',
        (tester) async {
      final container = await pumpApp(tester, ready: true);
      await tapRail(tester, 'Plan');
      await tester.scrollUntilVisible(
          find.text('What you hold once retired'), 300,
          scrollable: find.byType(Scrollable).first);

      await pick(tester, 'Move investments into', 'Bonds');
      final accounts = container
          .read(householdProvider)
          .accounts
          .where((a) => !a.kind.isCash);
      expect(accounts, isNotEmpty);
      for (final a in accounts) {
        expect(a.retirementAllocationId, 'bonds');
      }
    });

    testWidgets('and can be put back to leaving everything alone',
        (tester) async {
      final container = await pumpApp(tester, ready: true);
      await tapRail(tester, 'Plan');
      await tester.scrollUntilVisible(
          find.text('What you hold once retired'), 300,
          scrollable: find.byType(Scrollable).first);

      await pick(tester, 'Move investments into', 'Bonds');
      await pick(tester, 'Move investments into',
          'Leave everything where it is');
      for (final a in container.read(householdProvider).accounts) {
        expect(a.retirementAllocationId, isNull);
      }
    });
  });

  group('an assumption you can change is one you can put back', () {
    testWidgets('a rate of zero reads as zero, not as an empty box',
        (tester) async {
      // Bonds are pessimistic at 0% and a collectible appreciates at 0%. Both
      // rendered blank, so the only thing on screen was the floating label.
      await pumpApp(tester, ready: true);
      await tapRail(tester, 'Plan');
      await tester.scrollUntilVisible(find.text('What property does'), 300,
          scrollable: find.byType(Scrollable).first);

      final collectible = tester.widget<TextFormField>(
          find.widgetWithText(TextFormField, 'Collectible'));
      expect(collectible.initialValue, '0');
    });

    testWidgets('resetting is offered only once something has moved',
        (tester) async {
      final container = await pumpApp(tester, ready: true);
      await tapRail(tester, 'Plan');
      await tester.scrollUntilVisible(find.text('What property does'), 300,
          scrollable: find.byType(Scrollable).first);

      final button = find.widgetWithText(TextButton, 'Reset to defaults').last;
      expect(tester.widget<TextButton>(button).onPressed, isNull,
          reason: 'nothing has been changed yet');

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Vehicle'), '-3');
      await tester.pump();
      expect(tester.widget<TextButton>(button).onPressed, isNotNull);

      await tester.tap(button);
      await tester.pump();
      expect(
          container.read(scenarioProvider).assumptions
              .assetAppreciationByCategory,
          Assumptions.defaultAssetAppreciation);
    });

    testWidgets('and puts the returns back too', (tester) async {
      final container = await pumpApp(tester, ready: true);
      await tapRail(tester, 'Plan');
      await tester.scrollUntilVisible(
          find.text('What each holding earns'), 300,
          scrollable: find.byType(Scrollable).first);

      final field = find.descendant(
        of: find.ancestor(
            of: find.text('Bonds'), matching: find.byType(Card)),
        matching: find.widgetWithText(TextFormField, 'Expected'),
      );
      await tester.enterText(field, '9');
      await tester.pump();

      await tester.tap(
          find.widgetWithText(TextButton, 'Reset to defaults').first);
      await tester.pump();
      expect(container.read(assetClassesProvider), AssetClass.defaults);
    });
  });

  group('formatting', () {
    test('engine vocabulary becomes a form label', () {
      expect(humanise('marriedFilingJointly'), 'Married filing jointly');
      expect(humanise('traditional401k'), 'Traditional401k');
      expect(humanise('roth'), 'Roth');
    });

    test('money and rates render in the units a user thinks in', () {
      expect(formatMoney(Money.dollars(1234.5)), r'$1,234.50');
      expect(formatPercent(0.04), '4%');
      expect(formatPercent(0.0325), '3.25%');
    });

    testWidgets('a percent field shows a rate a user can read', (tester) async {
      // (0.0145 * 100).toString() is "1.4500000000000002", and (0.04 * 100)
      // is "4.0". Both reach the field without formatting.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            PercentField(label: 'Medicare', initial: 0.0145, onChanged: (_) {}),
            PercentField(label: 'Withdrawal', initial: 0.04, onChanged: (_) {}),
          ]),
        ),
      ));
      expect(find.widgetWithText(TextFormField, '1.45'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '4'), findsOneWidget);
    });
  });
}
