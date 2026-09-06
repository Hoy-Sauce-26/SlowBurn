import 'dart:convert';
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
    {Household? household, Size size = const Size(1600, 1400)}) async {
  tester.view.physicalSize = size;
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

/// The dropdown carrying a given label. `find.byType` cannot be used here,
/// because these are `DropdownMenu<int?>` and friends rather than the raw type.
Finder dropdown(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((w) => w is DropdownMenu),
    );

/// A `DropdownMenu` keeps every entry in the tree whether the list is open or
/// not, so choosing means opening the field and then taking the last of the
/// matching items, which is the one the overlay put on top.
Future<void> pick(WidgetTester tester, String field, String value) async {
  await tester.tap(dropdown(field).first);
  await tester.pumpAndSettle();
  // Two fields on one form can offer the same entry, so the one to tap is
  // whichever is really on top: the open list's.
  var item = find.widgetWithText(MenuItemButton, value).hitTestable();
  if (item.evaluate().isEmpty) {
    // An open list scrolls to whatever was already chosen, which can leave
    // the entry being asked for above the fold.
    await tester.ensureVisible(find.widgetWithText(MenuItemButton, value).last);
    await tester.pumpAndSettle();
    item = find.widgetWithText(MenuItemButton, value).hitTestable();
  }
  await tester.tap(item.last);
  await tester.pumpAndSettle();
}

/// What a dropdown is currently showing.
String shown(WidgetTester tester, String field) =>
    tester
        .widget<TextField>(find.descendant(
            of: dropdown(field).first, matching: find.byType(TextField)))
        .controller
        ?.text ??
    '';

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
          find.widgetWithText(TextFormField, 'Name it (optional)'),
          'Family premium');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Cost per year'), '9600');
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

      await tester.tap(find.text('Include Social Security benefits in this plan'));
      await tester.pumpAndSettle();

      final amount = find.widgetWithText(TextFormField, 'Monthly benefit');
      await tester.ensureVisible(amount);
      await tester.pumpAndSettle();
      await tester.enterText(amount, '3200');

      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
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

  group('the household list', () {
  testWidgets('a person appears in the list once added', (tester) async {
    await pumpApp(tester, size: const Size(1100, 800));
    await tester.tap(find.text('Add a person'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Alex');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Alex'), findsOneWidget,
        reason: 'you cannot delete or correct someone you cannot see');

    // In the tree is not the same as on the screen.
    final rect = tester.getRect(find.text('Alex'));
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(rect.top, lessThan(screen.height),
        reason: 'the person is below the fold, behind the tax-return form');
    expect(rect.bottom, greaterThan(0));
  });

  });

  group('the add-a-person form asks questions, not model terms', () {
    testWidgets('birth year and month are picked, and months have names',
        (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('Add a person'));
      await tester.pumpAndSettle();

      // Picked rather than typed: a typo in a birth year moves every age gate
      // in the plan.
      expect(find.byType(NumberChoiceField), findsWidgets);
      await pick(tester, 'Birth month', 'September');
      expect(shown(tester, 'Birth month'), 'September',
          reason: 'months read as names, not as numbers');
    });

    testWidgets('coverage is only asked once a retirement age is set',
        (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('Add a person'));
      await tester.pumpAndSettle();

      expect(dropdown('Health coverage through work ends'),
          findsNothing, reason: 'nothing to extrapolate from yet');

      await pick(tester, 'Plan to retire at', '45');
      expect(dropdown('Health coverage through work ends'), findsWidgets);
    });

    testWidgets('coverage defaults to the year the job ends', (tester) async {
      final container = await pumpApp(tester);
      await tester.tap(find.text('Add a person'));
      await tester.pumpAndSettle();
      await pick(tester, 'Plan to retire at', '45');
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final person = container.read(householdProvider).people.single;
      expect(person.employerHealthCoverageEndYear,
          person.birthDate.year + 45 - 1,
          reason: 'coverage ends with the job unless a retiree plan carries on');
    });

    testWidgets('no field is labelled in the engine\'s own vocabulary',
        (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('Add a person'));
      await tester.pumpAndSettle();

      for (final jargon in [
        'HSA limit',
        'FRA',
        '59½',
        'includeInProjection',
        'Count on it',
      ]) {
        expect(find.textContaining(jargon), findsNothing,
            reason: '"$jargon" means nothing to someone who has not read the '
                'domain model');
      }
    });
  });

  group('a dropdown is not a trap', () {
    testWidgets('a retirement age can be taken back once picked',
        (tester) async {
      final container = await pumpApp(tester);
      await tester.tap(find.text('Add a person'));
      await tester.pumpAndSettle();

      // 45 sits near the top of the list, so it is built without scrolling.
      await pick(tester, 'Plan to retire at', '45');
      expect(dropdown('Health coverage through work ends'), findsWidgets);

      // And back again, which a plain number dropdown could not do.
      await pick(tester, 'Plan to retire at', 'Work it out for me');
      expect(dropdown('Health coverage through work ends'),
          findsNothing);

      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final person = container.read(householdProvider).people.single;
      expect(person.plannedRetirementAge, isNull);
      expect(person.employerHealthCoverageEndYear, isNull,
          reason: 'clearing the age clears what was extrapolated from it');
    });
  });

  group('a dropdown is a list, not a text box', () {
    testWidgets('letters that match nothing never reach the box',
        (tester) async {
      await pumpApp(tester, household: withPerson());
      await tester.tap(dropdown('State').first);
      await tester.pumpAndSettle();

      await tester.enterText(find.descendant(
          of: dropdown('State').first, matching: find.byType(TextField)),
          'New');
      await tester.pumpAndSettle();
      expect(shown(tester, 'State'), 'New', reason: 'a filter, so far');

      await tester.enterText(find.descendant(
          of: dropdown('State').first, matching: find.byType(TextField)),
          'Newq');
      await tester.pumpAndSettle();
      expect(shown(tester, 'State'), 'New',
          reason: 'no state reads like that, so the keystroke is refused');
    });

    testWidgets('a half-typed search gives way to the answer', (tester) async {
      await pumpApp(tester, household: withPerson());
      await tester.tap(dropdown('State').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.descendant(
          of: dropdown('State').first, matching: find.byType(TextField)),
          'New');
      await tester.pumpAndSettle();

      // Attention moves on without a choice being made.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(shown(tester, 'State'), 'Colorado',
          reason: 'the box shows what is chosen, never what was typed at it');
    });
  });

  group('the state field', () {
    test('covers the fifty states and DC, per §7.6', () {
      expect(usStateCodes, hasLength(51));
      expect(usStateCodes['MI'], 'Michigan');
      expect(usStateCodes.containsKey('PR'), isFalse,
          reason: 'Puerto Rico runs a separate system, not a state-style '
              'layer on the federal one');
    });

    testWidgets('shows states by name rather than by code', (tester) async {
      await pumpApp(tester, household: withPerson());
      expect(shown(tester, 'State'), 'Colorado');
      expect(find.text('CO'), findsNothing);
    });

    testWidgets('says so when a state has no bundled rules yet',
        (tester) async {
      // A zero that means "we do not know" must not look like a zero that
      // means "no tax here". The bundled 2026 ruleset now covers every state,
      // so this is checked against a ruleset with one taken out.
      final gappy = jsonDecode(File('assets/tax_years/2026.json')
          .readAsStringSync()) as Map<String, dynamic>;
      (gappy['stateRules'] as Map<String, dynamic>).remove('MI');

      final container = ProviderContainer(overrides: [
        taxYearProvider.overrideWith((ref) => parseTaxYear(jsonEncode(gappy))),
        householdProvider.overrideWith(() => _Fixed(withPerson())),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: lightTheme(), home: const HomeShell()),
      ));
      await tester.pump();

      container.read(householdProvider.notifier).saveTaxUnit(TaxUnit(
            id: 'tu1',
            householdId: 'h1',
            filingStatus: FilingStatus.single,
            stateCode: 'MI',
          ));
      await tester.pump();
      expect(find.textContaining('do not have Michigan'), findsOneWidget);
    });

    testWidgets('says nothing for any state, now that all of them are in',
        (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      for (final code in usStateCodes.keys) {
        container.read(householdProvider.notifier).saveTaxUnit(TaxUnit(
              id: 'tu1',
              householdId: 'h1',
              filingStatus: FilingStatus.single,
              stateCode: code,
            ));
        await tester.pump();
        expect(find.textContaining('do not have'), findsNothing,
            reason: '$code has no bundled rules');
      }
    });
  });

  group('the household leaves nothing orphaned', () {
    testWidgets('cancelling Add a person leaves no tax return behind',
        (tester) async {
      final container = await pumpApp(tester);
      expect(find.text('How you file'), findsNothing);

      await tester.tap(find.text('Add a person'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(container.read(householdProvider).taxUnits, isEmpty);
      expect(find.text('How you file'), findsNothing,
          reason: 'a return nobody files is not a state anyone means to be in');
    });

    testWidgets('deleting the last person removes the return too',
        (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      expect(find.text('How you file'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();

      expect(container.read(householdProvider).people, isEmpty);
      expect(container.read(householdProvider).taxUnits, isEmpty);
      expect(find.text('How you file'), findsNothing);
    });
  });

  group('the income screen is three sections, not one list', () {
    testWidgets('each kind of thing has its own heading and add button',
        (tester) async {
      await pumpApp(tester, household: withPerson());
      await go(tester, 'Income');

      expect(find.text('Taken from your pay'), findsOneWidget);
      expect(find.text('Employers'), findsOneWidget);
      expect(find.text('Add income'), findsOneWidget);
      expect(find.text('Add a payroll deduction'), findsOneWidget);
      expect(find.text('Add an employer'), findsOneWidget);

      // Employers come first, because pay hangs off one and an income with no
      // employer to point at is a dead end.
      final employers = tester.getTopLeft(find.text('Employers')).dy;
      final income = tester.getTopLeft(find.text('Income').last).dy;
      expect(employers, lessThan(income));
    });

    testWidgets('income names itself after whoever earns it',
        (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Income');
      await tester.tap(find.text('Add an employer'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Name'), 'Acme');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add income'));
      await tester.pumpAndSettle();
      await pick(tester, 'Employer', 'Acme');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(container.read(householdProvider).incomeStreams.single.label,
          'Alex at Acme',
          reason: 'a label nobody had to think of still has to read like one');
    });

    testWidgets('a month is only asked once there is a year to put it in',
        (tester) async {
      await pumpApp(tester, household: withPerson());
      await go(tester, 'Income');
      await tester.tap(find.text('Add income'));
      await tester.pumpAndSettle();

      expect(dropdown('From which month'), findsNothing);
      await pick(tester, 'Starts', DateTime.now().year.toString());
      expect(dropdown('From which month'), findsWidgets);
    });

    testWidgets('a new employer says what to do with it', (tester) async {
      final household = withPerson().copyWith(
        employers: const [Employer(id: 'e', householdId: 'h1', label: 'Acme')],
      );
      await pumpApp(tester, household: household);
      await go(tester, 'Income');
      expect(find.textContaining('Not linked to anything yet'), findsOneWidget,
          reason: '"0 income · 0 accounts" told the user nothing to do');
    });

    testWidgets('a deduction names itself after whoever pays it',
        (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Income');
      await tester.tap(find.text('Add a payroll deduction'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Cost per year'), '9600');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(container.read(householdProvider).payrollDeductions.single.label,
          "Alex's health premium");
    });

    testWidgets('two people\'s deductions read differently', (tester) async {
      final household = withPerson().copyWith(
        people: [
          ...withPerson().people,
          Person(
            id: 'p2',
            displayName: 'Masha',
            birthDate: DateTime(1987, 2, 1),
            taxUnitId: 'tu1',
          ),
        ],
        payrollDeductions: const [
          PayrollDeduction(
            id: 'd1',
            personId: 'p1',
            label: "Alex's health fsa",
            kind: PayrollDeductionKind.healthFsa,
            annualAmount: Money(300000),
          ),
          PayrollDeduction(
            id: 'd2',
            personId: 'p2',
            label: "Masha's health fsa",
            kind: PayrollDeductionKind.healthFsa,
            annualAmount: Money(250000),
          ),
        ],
      );
      await pumpApp(tester, household: household);
      await go(tester, 'Income');
      expect(find.text("Alex's health fsa"), findsOneWidget);
      expect(find.text("Masha's health fsa"), findsOneWidget);
    });
  });
}
