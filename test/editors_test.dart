import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slow_burn/screens/home_shell.dart';
import 'package:slow_burn/services/providers.dart';
import 'package:slow_burn/theme/app_theme.dart';

final taxYear =
    parseTaxYear(File('assets/tax_years/2026.json').readAsStringSync());

Household withPerson() => Household(
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
          birthDate: DateTime(1985, 6, 15),
          taxUnitId: 'tu1',
        ),
      ],
    );

class _Fixed extends HouseholdNotifier {
  _Fixed(this._h);
  final Household _h;
  @override
  Household build() => _h;
}

Future<ProviderContainer> pumpApp(WidgetTester tester,
    {Household? household}) async {
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(overrides: [
    taxYearProvider.overrideWith((ref) => taxYear),
    if (household != null) householdProvider.overrideWith(() => _Fixed(household)),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(theme: lightTheme(), home: const HomeShell()),
  ));
  await tester.pump();
  return container;
}

Future<void> go(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).first);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the entities Stage 7 left unreachable', () {
    testWidgets('an employer can be added, which is what links pay to a plan',
        (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Income');
      await tester.tap(find.text('Add an employer'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Name'), 'Acme');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(container.read(householdProvider).employers.single.label, 'Acme');
    });

    testWidgets('a payroll deduction reaches FICA wages', (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Income');
      await tester.tap(find.text('Add a payroll deduction'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Label'), 'Family premium');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'A year'), '9600');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = container.read(householdProvider).payrollDeductions.single;
      expect(saved.annualAmount, Money.dollars(9600));
      expect(saved.reducesFicaWages, isTrue,
          reason: 'a §125 health premium reduces FICA wages; a 401(k) '
              'deferral does not');
    });

    testWidgets('a one-off outflow records where the money comes from',
        (tester) async {
      final household = withPerson().copyWith(accounts: [
        Account(
          id: 'a1',
          personId: 'p1',
          label: 'Brokerage',
          kind: AccountKind.taxableBrokerage,
          taxTreatment: TaxTreatment.taxable,
          limitFamily: LimitFamily.none,
          balance: Money.dollars(100000),
          costBasis: Money.dollars(80000),
          isRestrictedPurpose: false,
          contribution:
              const Contribution(mode: ContributionMode.fixedAmount, value: 0),
        ),
      ]);
      final container = await pumpApp(tester, household: household);
      await go(tester, 'Spending');
      await tester.tap(find.text('Add a one-off'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Label'), 'Truck');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Amount'), '40000');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final event = container.read(householdProvider).oneTimeEvents.single;
      expect(event.isOutflow, isTrue);
      expect(event.amount, Money.dollars(-40000));
      expect(event.accountId, 'a1',
          reason: 'invariant 17: an outflow must name its source');
      expect(validateHousehold(container.read(householdProvider)), isEmpty);
    });

    testWidgets('Social Security is entered on the person it belongs to',
        (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      await tester.tap(find.text('Alex'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Include Social Security'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Monthly benefit at FRA'), '3200');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final benefit =
          container.read(householdProvider).people.single.socialSecurity;
      expect(benefit, isNotNull);
      expect(benefit!.estimatedMonthlyBenefitAtFra, Money.dollars(3200));
      expect(benefit.personId, 'p1',
          reason: 'the benefit names the person it belongs to');
      expect(benefit.claimingAge, inInclusiveRange(62, 70));
      expect(validateHousehold(container.read(householdProvider)), isEmpty);
    });
  });

  group('the match, now that an employer can exist', () {
    testWidgets('an account sponsored by an employer can carry one',
        (tester) async {
      final household = withPerson().copyWith(
        employers: const [
          Employer(id: 'emp', householdId: 'h1', label: 'Acme'),
        ],
      );
      final container = await pumpApp(tester, household: household);
      await go(tester, 'Accounts');
      await tester.tap(find.text('Add an account'));
      await tester.pumpAndSettle();

      // A 401(k) is the default kind, so the sponsor field is offered.
      expect(find.text('Sponsored by'), findsOneWidget);
      await tester.tap(find.text('No employer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Acme').last);
      await tester.pumpAndSettle();

      expect(find.text('Employer matches contributions'), findsOneWidget,
          reason: 'a match needs an employer with pay behind it');

      await tester.tap(find.text('Employer matches contributions'));
      await tester.pumpAndSettle();

      // Enabling the match adds four fields, so Save moves below the fold.
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final account = container.read(householdProvider).accounts.single;
      expect(account.employerId, 'emp');
      expect(account.contribution.employerMatch, isNotNull);
      expect(account.contribution.employerMatch!.matchRate, 0.5);
    });

    testWidgets('an account with no employer is offered no match',
        (tester) async {
      await pumpApp(tester, household: withPerson());
      await go(tester, 'Accounts');
      await tester.tap(find.text('Add an account'));
      await tester.pumpAndSettle();
      expect(find.text('Employer matches contributions'), findsNothing,
          reason: 'compensation of zero yields no match, which is the right '
              'answer for an account no employer sponsors');
    });
  });
}
