import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slow_burn/screens/home_shell.dart';
import 'package:slow_burn/services/providers.dart';
import 'package:slow_burn/theme/app_theme.dart';
import 'package:slow_burn/widgets/results_panel.dart';

Household funded() => Household(
      id: 'h1',
      taxUnits: [
        TaxUnit(
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
          birthDate: DateTime(1975, 6, 15),
          taxUnitId: 'tu1',
        ),
      ],
      incomeStreams: [
        IncomeStream(
          id: 'inc1',
          personId: 'p1',
          label: 'Salary',
          kind: IncomeKind.w2Wages,
          grossAnnualAmount: Money.dollars(200000),
          isFicaSubject: true,
          isQualifiedBusinessIncome: false,
        ),
      ],
      accounts: [
        Account(
          id: 'k1',
          personId: 'p1',
          label: '401(k)',
          kind: AccountKind.taxableBrokerage,
          taxTreatment: TaxTreatment.taxable,
          limitFamily: LimitFamily.none,
          balance: Money.dollars(2500000),
          costBasis: Money.dollars(2000000),
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
      expenseItems: const [
        ExpenseItem(
          id: 'e1',
          categoryId: 'cat',
          label: 'Living',
          amount: Money(6000000),
        ),
      ],
    );

/// Read straight off disk rather than through the asset bundle. The shell test
/// is about layout, and leaving an unresolved future in it makes every
/// assertion a race with asset IO. `tax_year_service_test.dart` covers the
/// bundle path on its own.
final taxYear =
    parseTaxYear(File('assets/tax_years/2026.json').readAsStringSync());

Future<void> pumpShell(
  WidgetTester tester, {
  required Size size,
  Household? household,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        taxYearProvider.overrideWith((ref) => taxYear),
        if (household != null)
          householdProvider.overrideWith(() => _FixedHousehold(household)),
      ],
      child: MaterialApp(theme: lightTheme(), home: const HomeShell()),
    ),
  );
  // Not pumpAndSettle: a progress indicator is an indefinite animation and
  // never settles. One extra frame is enough now that the tax year is supplied
  // rather than loaded.
  await tester.pump();
}

class _FixedHousehold extends HouseholdNotifier {
  _FixedHousehold(this._household);
  final Household _household;
  @override
  Household build() => _household;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the shell opens on the first destination', (tester) async {
    await pumpShell(tester, size: const Size(1440, 900));
    expect(find.text('Slow Burn'), findsOneWidget);
    expect(find.text('Household'), findsWidgets);
  });

  testWidgets('a desktop window shows the results panel beside the content',
      (tester) async {
    await pumpShell(tester, size: const Size(1440, 900));
    expect(find.byType(ResultsPanel), findsOneWidget);
    expect(find.text('Your plan'), findsOneWidget);
  });

  testWidgets('a phone gets Results as a destination instead', (tester) async {
    await pumpShell(tester, size: const Size(390, 844));
    // Not beside the content, but reachable.
    expect(find.byType(ResultsPanel), findsNothing);
    expect(find.text('Results'), findsWidgets);
  });

  testWidgets('an empty household says so rather than showing a blank',
      (tester) async {
    await pumpShell(tester, size: const Size(1440, 900));
    expect(find.text('No projection yet'), findsOneWidget);
  });

  testWidgets('a funded household shows the three headlines', (tester) async {
    await pumpShell(
      tester,
      size: const Size(1440, 1200),
      household: funded(),
    );
    expect(find.text('Retirement year'), findsOneWidget);
    expect(find.text('FIRE number'), findsOneWidget);
    expect(find.text('Sustainable spending'), findsOneWidget);
  });
}
