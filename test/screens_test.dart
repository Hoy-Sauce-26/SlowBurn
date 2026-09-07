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
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      taxYearProvider.overrideWith((ref) => taxYear),
      if (ready) ...[
        setupProgressProvider.overrideWith(() => _Declared()),
        householdProvider.overrideWith(() => _Fixed(readyHousehold())),
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
Future<void> pick(WidgetTester tester, String field, String value) async {
  final menu = find.ancestor(
      of: find.text(field),
      matching: find.byWidgetPredicate((w) => w is DropdownMenu));
  await tester.tap(menu.first);
  await tester.pumpAndSettle();
  var item = find.widgetWithText(MenuItemButton, value).hitTestable();
  if (item.evaluate().isEmpty) {
    await tester.ensureVisible(find.widgetWithText(MenuItemButton, value).last);
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
