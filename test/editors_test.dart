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
  // The app opens on Plan, which is the checklist until a plan is declared
  // ready. These tests are about the editors, so they start where the entities
  // are.
  await go(tester, 'Household');
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
          find.widgetWithText(TextFormField, 'Name it (optional)'), 'Truck');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Amount'), '40000');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final event = container.read(householdProvider).oneTimeEvents.single;
      expect(event.isOutflow, isTrue);
      expect(event.amount, Money.dollars(-40000));
      expect(event.accountId, 'a1',
          reason: 'invariant 16: an outflow must name its source');
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
      expect(dropdown('Sponsored by'), findsWidgets);
      await pick(tester, 'Sponsored by', 'Acme');

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

    testWidgets('an old plan is not asked how much of a salary goes in',
        (tester) async {
      // A 401(k) from a job you left still grows and takes nothing in. Asking
      // for a share of pay would be asking about pay nobody is receiving, so
      // an account starts dormant and naming a job is what wakes it.
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Accounts');
      await tester.tap(find.text('Add an account'));
      await tester.pumpAndSettle();

      expect(find.text('Still paying into it'), findsOneWidget);
      expect(dropdown('Put in'), findsNothing);
      expect(find.widgetWithText(TextFormField, 'Each year'), findsNothing);
      expect(dropdown('Last year you pay in'), findsNothing);

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Balance'), '120000');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final account = container.read(householdProvider).accounts.single;
      expect(account.contribution.value, 0);
      expect(account.contribution.endYear, isNull);
    });

    testWidgets('a share of pay is only offered where there is pay',
        (tester) async {
      final household = withPerson().copyWith(
        employers: const [
          Employer(id: 'emp', householdId: 'h1', label: 'Acme'),
        ],
      );
      await pumpApp(tester, household: household);
      await go(tester, 'Accounts');
      await tester.tap(find.text('Add an account'));
      await tester.pumpAndSettle();

      expect(dropdown('Put in'), findsNothing,
          reason: 'no sponsor chosen yet, so a share of what?');
      expect(find.widgetWithText(TextFormField, 'Each year'), findsNothing,
          reason: 'a new account is dormant until a job is named');

      await pick(tester, 'Sponsored by', 'Acme');
      expect(dropdown('Put in'), findsWidgets,
          reason: 'naming a current job says money is going in');

      await pick(tester, 'Sponsored by', 'An old job, or none');
      expect(dropdown('Put in'), findsNothing,
          reason: 'taking the job away says the opposite');
      expect(dropdown('Last year you pay in'), findsNothing);
    });

    testWidgets('an account names itself after the job it came with',
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
      await pick(tester, 'Sponsored by', 'Acme');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(container.read(householdProvider).accounts.single.label,
          'Acme 401(k)');
    });

    testWidgets('two old plans of the same kind are told apart',
        (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      for (var i = 0; i < 2; i++) {
        await go(tester, 'Accounts');
        await tester.tap(find.text('Add an account'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Save'));
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
      }

      final labels =
          container.read(householdProvider).accounts.map((a) => a.label);
      expect(labels, ["Alex's 401(k)", "Alex's 401(k) 2"],
          reason: 'two plans from two old jobs cannot share one name');
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

  group('an account is asked only what it needs', () {
    testWidgets('what it is held in follows what kind it is', (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Accounts');
      await tester.tap(find.text('Add an account'));
      await tester.pumpAndSettle();

      expect(shown(tester, 'Invested in'), 'US stocks',
          reason: 'a 401(k) is the default kind');

      // Savings and checking are not the same holding: one is paid interest
      // against inflation and the other is only eroded by it.
      await pick(tester, 'Kind', 'Savings');
      expect(shown(tester, 'Invested in'), 'Savings interest');

      await pick(tester, 'Kind', 'Checking');
      expect(shown(tester, 'Invested in'), 'Cash, earning nothing');

      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(container.read(householdProvider).accounts.single.assetAllocationId,
          'cash');
    });

    testWidgets('a bank account is not asked what it paid for its money',
        (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Accounts');
      await tester.tap(find.text('Add an account'));
      await tester.pumpAndSettle();
      await pick(tester, 'Kind', 'Savings');

      expect(find.widgetWithText(TextFormField, 'What you paid for it'),
          findsNothing);
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Balance'), '40000');
      await tester.pump();
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final account = container.read(householdProvider).accounts.single;
      expect(account.costBasis, account.balance,
          reason: 'every dollar in a bank has already been taxed');
    });

    testWidgets('an emergency fund is a target, offered only on cash',
        (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Accounts');
      await tester.tap(find.text('Add an account'));
      await tester.pumpAndSettle();

      expect(dropdown('Emergency fund'), findsNothing,
          reason: 'a 401(k) is not where anyone keeps one');

      await pick(tester, 'Kind', 'Savings');
      expect(dropdown('Emergency fund'), findsWidgets);
      expect(shown(tester, 'Emergency fund'), 'Not the account I keep one in',
          reason: 'a target nobody set should not quietly become one');

      await pick(tester, 'Emergency fund', '6 months');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(container.read(householdProvider).accounts.single
          .targetBalanceMonths, 6);
    });

    testWidgets('a dormant account saves as nothing, not as a share of nothing',
        (tester) async {
      // The switch hid the fields but left the mode alone, so an old plan for
      // somebody with no job saved as 0% of a salary that does not exist and
      // blocked the projection.
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Accounts');
      await tester.tap(find.text('Add an account'));
      await tester.pumpAndSettle();
      await pick(tester, 'Kind', 'TSP');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Balance'), '90000');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = container.read(householdProvider);
      final contribution = saved.accounts.single.contribution;
      expect(contribution.mode, ContributionMode.fixedAmount);
      expect(contribution.value, 0);
      expect(contribution.contributionBaseStreamIds, isEmpty);
      expect(validateHousehold(saved), isEmpty,
          reason: 'a dormant plan is not a data-entry error');
    });

    testWidgets('a brokerage is still asked, in words', (tester) async {
      await pumpApp(tester, household: withPerson());
      await go(tester, 'Accounts');
      await tester.tap(find.text('Add an account'));
      await tester.pumpAndSettle();
      await pick(tester, 'Kind', 'Brokerage');

      expect(find.widgetWithText(TextFormField, 'What you paid for it'),
          findsOneWidget);
      expect(find.text('Cost basis'), findsNothing);
    });
  });

  group('what the app already knows, it does not ask', () {
    testWidgets('a car does not start out appreciating like a house',
        (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Property');
      await tester.tap(find.text('Add something you own').last);
      await tester.pumpAndSettle();

      final house = tester.widget<TextFormField>(
          find.widgetWithText(TextFormField, 'Gains value at'));
      expect(house.initialValue, '0.5');

      await pick(tester, 'Category', 'Vehicle');
      final car = tester.widget<TextFormField>(
          find.widgetWithText(TextFormField, 'Gains value at'));
      expect(car.initialValue, '-10');

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Value today'), '30000');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
          container.read(householdProvider).assets.single.realAppreciationRate,
          closeTo(-0.10, 1e-9));
    });

    testWidgets('children can be added, having gone missing entirely',
        (tester) async {
      // Dependants drive the Child Tax Credit and the household size behind
      // every health subsidy, and had no editor at all.
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Household');
      await tester.tap(find.text('Add a dependant'));
      await tester.pumpAndSettle();

      await pick(tester, 'Born', '${DateTime.now().year - 8}');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final unit = container.read(householdProvider).taxUnits.single;
      expect(unit.dependents, hasLength(1));
      expect(unit.dependents.single.birthDate.year, DateTime.now().year - 8);
      expect(unit.dependents.single.resolvedSupportEndYear,
          DateTime.now().year - 8 + 19);
    });
  });

  group('buying something later', () {
    testWidgets('a house bought in ten years is enterable at all',
        (tester) async {
      // The engine has handled a future purchase since §3.5 was written. The
      // editor never asked for the year, so there was no way to say it.
      final household = withPerson().copyWith(accounts: [
        Account(
          id: 'a1',
          personId: 'p1',
          label: 'Brokerage',
          kind: AccountKind.taxableBrokerage,
          taxTreatment: TaxTreatment.taxable,
          limitFamily: LimitFamily.none,
          balance: Money.dollars(300000),
          costBasis: Money.dollars(200000),
          isRestrictedPurpose: false,
          contribution:
              const Contribution(mode: ContributionMode.fixedAmount, value: 0),
        ),
      ]);
      final container = await pumpApp(tester, household: household);
      await go(tester, 'Property');
      await tester.tap(find.text('Add something you own').last);
      await tester.pumpAndSettle();

      await pick(tester, 'When you get it', '${DateTime.now().year + 10}');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'What it will cost'), '500000');
      await pick(tester, 'Paid for from', 'Brokerage');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final asset = container.read(householdProvider).assets.single;
      expect(asset.acquisitionYear, DateTime.now().year + 10);
      expect(asset.purchaseFundingAccountId, 'a1');
      expect(asset.costBasis, Money.dollars(500000));
      expect(asset.currentValue, asset.costBasis,
          reason: '§3.5: it enters at what it cost, so there is no separate '
              'value today to hold');
      expect(asset.heldIn(DateTime.now().year), isFalse,
          reason: 'it counts for nothing until it is bought');
      expect(asset.heldIn(DateTime.now().year + 10), isTrue);
    });

    testWidgets('and answers the housing question from that year',
        (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Property');
      await tester.tap(find.text('Add something you own').last);
      await tester.pumpAndSettle();
      await pick(tester, 'When you get it', '${DateTime.now().year + 5}');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'What it will cost'), '500000');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = container.read(householdProvider);
      expect(housedIn(saved, DateTime.now().year), isFalse);
      expect(housedIn(saved, DateTime.now().year + 5), isTrue);
    });

    testWidgets('an inheritance names no account to pay from', (tester) async {
      await pumpApp(tester, household: withPerson());
      await go(tester, 'Property');
      await tester.tap(find.text('Add something you own').last);
      await tester.pumpAndSettle();

      expect(dropdown('Paid for from'), findsNothing,
          reason: 'nothing to pay for until a purchase year is named');
      await pick(tester, 'When you get it', '${DateTime.now().year + 3}');
      expect(dropdown('Paid for from'), findsNothing,
          reason: 'this household holds no accounts to pay from');
    });
  });

  group('a roof and its bills keep the same dates', () {
    Household owning({int? soldIn}) => withPerson().copyWith(
          assets: [
            Asset(
              id: 'house',
              householdId: 'h1',
              label: 'House',
              category: AssetCategory.primaryResidence,
              currentValue: Money.dollars(600000),
              costBasis: Money.dollars(450000),
              plannedSaleYear: soldIn,
              saleProceedsAccountId: soldIn == null ? null : 'acct',
            ),
          ],
          expenseCategories: const [
            ExpenseCategory(
                id: 'bills',
                householdId: 'h1',
                label: 'Housing costs',
                metaCategory: MetaCategory.housingSupport),
          ],
          expenseItems: [
            ExpenseItem(
              id: 'tax',
              categoryId: 'bills',
              label: 'Property tax',
              amount: Money.dollars(9000),
              frequency: ExpenseFrequency.annual,
              // Dated as the cascade would have left it.
              endYear: soldIn == null ? null : soldIn - 1,
              housingId: 'house',
            ),
          ],
        );

    testWidgets('tying a cost to a home adopts that home\'s dates',
        (tester) async {
      final container = await pumpApp(tester, household: owning(soldIn: 2046));
      await go(tester, 'Spending');
      await tester.tap(find.text('Add to housing costs'));
      await tester.pumpAndSettle();
      await pick(tester, 'For which home', 'House, until 2045');
      expect(find.textContaining('Runs with House, until 2045'),
          findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Amount'), '3000');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final added = container
          .read(householdProvider)
          .expenseItems
          .firstWhere((i) => i.id != 'tax');
      expect(added.housingId, 'house');
      expect(added.endYear, 2045);
    });

    testWidgets('a home is offered with the years it covers', (tester) async {
      await pumpApp(tester, household: owning(soldIn: 2046));
      await go(tester, 'Spending');
      await tester.tap(find.text('Property tax'));
      await tester.pumpAndSettle();
      expect(shown(tester, 'For which home'), 'House, until 2045');
    });

    testWidgets('tying an existing cost moves its dates on screen',
        (tester) async {
      // Reported: the field updates on save but the form does not show it.
      final untied = owning(soldIn: 2046).copyWith(
        expenseItems: [
          ExpenseItem(
            id: 'tax',
            categoryId: 'bills',
            label: 'Property tax',
            amount: Money.dollars(9000),
            frequency: ExpenseFrequency.annual,
          ),
        ],
      );
      await pumpApp(tester, household: untied);
      await go(tester, 'Spending');
      await tester.tap(find.text('Property tax'));
      await tester.pumpAndSettle();

      // Its own dates until it is tied to something, and then the home's.
      expect(shown(tester, 'Ends'), 'It carries on');
      await pick(tester, 'For which home', 'House, until 2045');

      expect(dropdown('Ends'), findsNothing,
          reason: 'a cost that follows a home has no dates of its own, and '
              'two dropdowns that are really derived read as editable');
      expect(dropdown('Starts'), findsNothing);
      expect(find.textContaining('Runs with House, until 2045'),
          findsOneWidget);
    });

    testWidgets('and can be given its own dates back', (tester) async {
      await pumpApp(tester, household: owning(soldIn: 2046));
      await go(tester, 'Spending');
      await tester.tap(find.text('Property tax'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Runs with House'), findsOneWidget);
      await tester.ensureVisible(find.text('Give it its own dates'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Give it its own dates'));
      await tester.pumpAndSettle();

      expect(dropdown('Ends'), findsWidgets);
      expect(shown(tester, 'Ends'), '2045',
          reason: 'it keeps the dates it had, and they are now editable');
    });

    testWidgets('moving the sale year moves the tax with it', (tester) async {
      final container = await pumpApp(tester, household: owning(soldIn: 2046));
      final notifier = container.read(householdProvider.notifier);
      final house = container.read(householdProvider).assets.single;

      notifier.saveAsset(Asset(
        id: house.id,
        householdId: house.householdId,
        label: house.label,
        category: house.category,
        currentValue: house.currentValue,
        costBasis: house.costBasis,
        plannedSaleYear: 2038,
        saleProceedsAccountId: 'acct',
      ));

      expect(container.read(householdProvider).expenseItems.single.endYear,
          2037,
          reason: 'the bills end the year before the house is sold');
    });

    testWidgets('and a house nobody sells leaves them open-ended',
        (tester) async {
      final container = await pumpApp(tester, household: owning(soldIn: 2046));
      final notifier = container.read(householdProvider.notifier);
      final house = container.read(householdProvider).assets.single;

      notifier.saveAsset(Asset(
        id: house.id,
        householdId: house.householdId,
        label: house.label,
        category: house.category,
        currentValue: house.currentValue,
        costBasis: house.costBasis,
      ));
      expect(container.read(householdProvider).expenseItems.single.endYear,
          isNull);
    });

    testWidgets('a cost tied to nothing is left alone', (tester) async {
      final loose = owning(soldIn: 2046).copyWith(
        expenseItems: [
          ExpenseItem(
            id: 'tax',
            categoryId: 'bills',
            label: 'Property tax',
            amount: Money.dollars(9000),
            frequency: ExpenseFrequency.annual,
            endYear: 2060,
          ),
        ],
      );
      final container = await pumpApp(tester, household: loose);
      final house = container.read(householdProvider).assets.single;
      container.read(householdProvider.notifier).saveAsset(Asset(
            id: house.id,
            householdId: house.householdId,
            label: house.label,
            category: house.category,
            currentValue: house.currentValue,
            costBasis: house.costBasis,
            plannedSaleYear: 2038,
            saleProceedsAccountId: 'acct',
          ));
      expect(container.read(householdProvider).expenseItems.single.endYear,
          2060,
          reason: 'unattached means it keeps its own dates');
    });
  });

  group('an editor is not dismissed by a stray click', () {
    testWidgets('clicking beside the form leaves it open', (tester) async {
      // The trap: the form scrolls, so a click aimed at a control below the
      // fold lands on the scrim and throws away everything typed so far.
      await pumpApp(tester, household: withPerson());
      await go(tester, 'Spending');
      await tester.tap(find.text('Add spending'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Amount'), '1234');
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, 'Amount'), findsOneWidget,
          reason: 'a half-filled editor should not vanish');
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('and the close button still closes it', (tester) async {
      await pumpApp(tester, household: withPerson());
      await go(tester, 'Spending');
      await tester.tap(find.text('Add spending'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('Save'), findsNothing);
    });
  });

  group('housing costs sit under the roof they pay for', () {
    testWidgets('grouped by home, with anything loose called out',
        (tester) async {
      final h = withPerson().copyWith(
        assets: [
          Asset(
            id: 'house',
            householdId: 'h1',
            label: 'House',
            category: AssetCategory.primaryResidence,
            currentValue: Money.dollars(600000),
            costBasis: Money.dollars(450000),
            plannedSaleYear: 2046,
            saleProceedsAccountId: 'acct',
          ),
        ],
        expenseCategories: const [
          ExpenseCategory(
              id: 'bills',
              householdId: 'h1',
              label: 'Housing costs',
              metaCategory: MetaCategory.housingSupport),
        ],
        expenseItems: [
          ExpenseItem(
            id: 'tax',
            categoryId: 'bills',
            label: 'Property tax',
            amount: Money.dollars(9000),
            frequency: ExpenseFrequency.annual,
            endYear: 2045,
            housingId: 'house',
          ),
          ExpenseItem(
            id: 'phone',
            categoryId: 'bills',
            label: 'Broadband',
            amount: Money.dollars(900),
            frequency: ExpenseFrequency.annual,
          ),
        ],
      );
      await pumpApp(tester, household: h);
      await go(tester, 'Spending');

      expect(find.text('House, until 2045'), findsOneWidget);
      expect(find.text('Not tied to a home'), findsOneWidget);

      final tied = tester.getTopLeft(find.text('Property tax')).dy;
      final under = tester.getTopLeft(find.text('House, until 2045')).dy;
      final loose = tester.getTopLeft(find.text('Not tied to a home')).dy;
      expect(under, lessThan(tied));
      expect(tied, lessThan(loose),
          reason: 'the unattached group comes last, being the one worth '
              'noticing');
    });
  });

  group('renting is an answer', () {
    testWidgets('the property page offers it when nothing is owned',
        (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Property');
      expect(find.text('I rent'), findsOneWidget);

      await tester.tap(find.text('I rent'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Rent a month'), '1800');
      await tester.tap(find.text('Add it'));
      await tester.pumpAndSettle();

      final saved = container.read(householdProvider);
      expect(saved.expenseItems.single.amount, Money.dollars(21600));
      expect(saved.expenseItems.single.startYear, isNull,
          reason: 'rent already being paid starts now, not in a named year');
      expect(housedIn(saved, DateTime.now().year), isTrue);
      expect(find.text('I rent'), findsNothing);
    });
  });

  group('somewhere to live', () {
    testWidgets('selling a home asks where they will live', (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Property');
      await tester.tap(find.text('Add something you own').last);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Value today'), '600000');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Planned sale year'), '2040');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Where will you live from 2040?'), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Rent a month, from 2040'),
          '2000');
      await tester.tap(find.text('Add it'));
      await tester.pumpAndSettle();

      final saved = container.read(householdProvider);
      final rent = saved.expenseItems.single;
      expect(rent.amount, Money.dollars(24000));
      expect(rent.startYear, 2040);
      expect(housedIn(saved, 2041), isTrue);
    });

    testWidgets('and takes no for an answer', (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      await go(tester, 'Property');
      await tester.tap(find.text('Add something you own').last);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Value today'), '600000');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Planned sale year'), '2040');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('I will sort it out later'));
      await tester.pumpAndSettle();
      expect(container.read(householdProvider).expenseItems, isEmpty);
    });

    testWidgets('a home nobody is selling is not asked about', (tester) async {
      await pumpApp(tester, household: withPerson());
      await go(tester, 'Property');
      await tester.tap(find.text('Add something you own').last);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Value today'), '600000');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Where will you live'), findsNothing);
    });
  });

  group('a name nobody had to think of', () {
    testWidgets('a debt is named after what it is secured against',
        (tester) async {
      final household = withPerson().copyWith(assets: [
        Asset(
          id: 'as1',
          householdId: 'h1',
          label: 'House',
          category: AssetCategory.primaryResidence,
          currentValue: Money.dollars(600000),
          costBasis: Money.dollars(450000),
        ),
      ]);
      final container = await pumpApp(tester, household: household);
      await go(tester, 'Property');
      await tester.tap(find.text('Add a debt').last);
      await tester.pumpAndSettle();
      await pick(tester, 'Secured against', 'House');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final debt = container.read(householdProvider).liabilities.single;
      expect(debt.label, 'House mortgage');
      expect(debt.securedAssetId, 'as1');
    });

    testWidgets('linking a mortgage to a house links the house back',
        (tester) async {
      // Invariant 5 wants both ends to agree, and a user should not have to
      // know that.
      final household = withPerson().copyWith(assets: [
        Asset(
          id: 'as1',
          householdId: 'h1',
          label: 'House',
          category: AssetCategory.primaryResidence,
          currentValue: Money.dollars(600000),
          costBasis: Money.dollars(450000),
        ),
      ]);
      final container = await pumpApp(tester, household: household);
      await go(tester, 'Property');
      await tester.tap(find.text('Add a debt').last);
      await tester.pumpAndSettle();
      await pick(tester, 'Secured against', 'House');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = container.read(householdProvider);
      expect(saved.assets.single.securedByLiabilityId,
          saved.liabilities.single.id);
      expect(validateHousehold(saved), isEmpty);
    });

    testWidgets('a second car is not called the same as the first',
        (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      for (var i = 0; i < 2; i++) {
        await go(tester, 'Property');
        await tester.tap(find.text('Add something you own').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Save'));
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
      }
      expect(container.read(householdProvider).assets.map((a) => a.label),
          ['House', 'House 2']);
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
      await go(tester, 'Household');

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
