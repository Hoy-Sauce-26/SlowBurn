import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slow_burn/screens/home_shell.dart';
import 'package:slow_burn/services/providers.dart';
import 'package:slow_burn/theme/app_theme.dart';
import 'package:slow_burn/widgets/fields.dart';

final taxYear =
    parseTaxYear(File('assets/tax_years/2026.json').readAsStringSync());

Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  Size size = const Size(1600, 1200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [taxYearProvider.overrideWith((ref) => taxYear)],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: lightTheme(), home: const HomeShell()),
    ),
  );
  await tester.pump();
  return container;
}

Future<void> tapRail(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).first);
  await tester.pump();
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
        ('Debts', 'Debts and assets'),
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
      final container = await pumpApp(tester);
      await tapRail(tester, 'Plan');

      final field = find.widgetWithText(TextFormField, '4');
      expect(field, findsOneWidget, reason: '4% is the default');
      await tester.enterText(field, '3.5');
      await tester.pump();

      expect(container.read(scenarioProvider).assumptions.safeWithdrawalRate,
          closeTo(0.035, 1e-9));
    });

    testWidgets('Social Security can be switched off entirely', (tester) async {
      final container = await pumpApp(tester);
      await tapRail(tester, 'Plan');
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      expect(container.read(scenarioProvider).assumptions.includeSocialSecurity,
          isFalse);
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
