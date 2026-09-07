import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slow_burn/screens/home_shell.dart';
import 'package:slow_burn/services/providers.dart';
import 'package:slow_burn/screens/housing_screen.dart';
import 'package:slow_burn/services/readiness.dart';
import 'package:slow_burn/theme/app_theme.dart';

final taxYear =
    parseTaxYear(File('assets/tax_years/2026.json').readAsStringSync());

Household withPerson() => Household(
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
    );

/// Somewhere to live, which the housing step now insists on.
Household renting(Household h) => h.copyWith(
      expenseCategories: [
        ...h.expenseCategories,
        const ExpenseCategory(
          id: 'housing',
          householdId: 'h1',
          label: 'Housing',
          metaCategory: MetaCategory.housing,
        ),
      ],
      expenseItems: [
        ...h.expenseItems,
        ExpenseItem(
          id: 'rent',
          categoryId: 'housing',
          label: 'Rent',
          amount: Money.dollars(24000),
          frequency: ExpenseFrequency.annual,
        ),
      ],
    );

Household spending(Household h) => h.copyWith(
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
    if (household != null)
      householdProvider.overrideWith(() => _Fixed(household)),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(theme: lightTheme(), home: const HomeShell()),
  ));
  await tester.pump();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the default asset classes', () {
    test('a bank account that pays interest is not the same as one that does '
        'not', () {
      final classes = ProviderContainer().read(assetClassesProvider);
      final savings =
          classes.firstWhere((c) => c.label == AssetClassLabel.savings);
      final cash = classes.firstWhere((c) => c.label == AssetClassLabel.cash);

      expect(savings.expectedRealReturn > cash.expectedRealReturn, isTrue);
      expect(cash.expectedRealReturn < 0, isTrue,
          reason: 'money earning nothing loses to inflation every year');
      expect(cash.incomeYield, 0, reason: 'nothing is paid out to tax');
      expect(savings.incomeYield > savings.expectedRealReturn, isTrue,
          reason: 'interest is taxed in full while inflation eats the '
              'principal, which is the decomposition §3.9 describes');
    });

    test('a plan saved before a class existed still gets offered it', () {
      // The one that broke it: a stored bundle replaced the built-in list
      // wholesale, so a savings account could not find a savings class and
      // fell back to whatever sorted first, which was shares.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final stored = AssetClassesNotifier.defaults
          .where((c) => c.label != AssetClassLabel.savings)
          .toList();

      container.read(assetClassesProvider.notifier).replace(stored);
      final classes = container.read(assetClassesProvider);
      expect(classes.any((c) => c.label == AssetClassLabel.savings), isTrue);
      expect(classes.length, AssetClassesNotifier.defaults.length);
    });

    test('a stored class is not overwritten by the one it shares an id with',
        () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final edited = AssetClassesNotifier.defaults
          .map((c) => c.label == AssetClassLabel.usStocks
              ? AssetClass(
                  id: c.id,
                  label: c.label,
                  expectedRealReturn: 0.03,
                  pessimisticRealReturn: c.pessimisticRealReturn,
                  optimisticRealReturn: c.optimisticRealReturn,
                  incomeYield: c.incomeYield,
                  qualifiedIncomeFraction: c.qualifiedIncomeFraction)
              : c)
          .toList();

      container.read(assetClassesProvider.notifier).replace(edited);
      final stocks = container
          .read(assetClassesProvider)
          .firstWhere((c) => c.label == AssetClassLabel.usStocks);
      expect(stocks.expectedRealReturn, 0.03);
    });
  });

  group('what a plan needs before it means anything', () {
    test('the steps run in the order a person thinks of them', () {
      expect(SetupStep.values.map((s) => s.name), [
        'people',
        'work',
        'accounts',
        'owned',
        'owed',
        'housing',
        'spending',
        'refinements',
      ]);
    });

    test('six steps gate a plan and the seventh does not', () {
      expect(SetupStep.values.where((s) => s.gates), hasLength(7));
      expect(SetupStep.refinements.gates, isFalse);
    });

    test('nobody spends nothing, and nobody is nobody', () {
      // Every other step can be answered "I have none of these". A renter owns
      // no property; a person who claims to spend nothing has not answered.
      expect(SetupStep.spending.canBeNone, isFalse);
      expect(SetupStep.people.canBeNone, isFalse);
      expect(SetupStep.housing.canBeNone, isFalse,
          reason: 'everybody lives somewhere');
      expect(SetupStep.owned.canBeNone, isTrue);
      expect(SetupStep.owed.canBeNone, isTrue);
      expect(SetupStep.work.canBeNone, isTrue,
          reason: 'somebody already retired has no job to enter');
    });

    test('passing a step counts as answering it', () {
      final h = withPerson();
      const none = SetupProgress();
      expect(none.isDone(SetupStep.owned, h), isFalse);
      expect(none.copyWith(passed: {SetupStep.owned}).isDone(SetupStep.owned, h),
          isTrue);
    });

    test('passing cannot be used to skip what the answer depends on', () {
      final h = withPerson();
      const claimed = SetupProgress(passed: {SetupStep.spending});
      expect(claimed.isDone(SetupStep.spending, h), isFalse,
          reason: 'spending is the input that decides the FIRE number');
    });

    test('the next step is the first one still unanswered', () {
      final h = withPerson();
      const progress = SetupProgress();
      expect(progress.nextFor(h), SetupStep.work);
      expect(
          progress
              .copyWith(passed: {SetupStep.work, SetupStep.accounts})
              .nextFor(h),
          SetupStep.owned);
    });

    test('declaring is only allowed once every step is answered', () {
      final h = spending(withPerson());
      const partway = SetupProgress();
      expect(partway.canDeclare(h), isFalse);

      final answered = partway.copyWith(passed: {
        SetupStep.work,
        SetupStep.accounts,
        SetupStep.owned,
        SetupStep.owed,
      });
      expect(answered.canDeclare(h), isFalse,
          reason: 'nowhere to live is still an unanswered question');
      expect(answered.isDone(SetupStep.housing, renting(h)), isTrue);
    });

    test('selling the car later does not send you back behind the gate', () {
      // Declaring is a one-way door for anything optional. Emptying the
      // spending is not optional, and closes it again.
      final h = spending(withPerson());
      const declared = SetupProgress(declaredReady: true);
      expect(declared.showsProjection(h), isTrue);
      expect(declared.showsProjection(withPerson()), isFalse,
          reason: 'no spending, no meaningful answer');
    });
  });

  group('the app holds its numbers back', () {
    testWidgets('a half-entered plan shows the checklist, not a date',
        (tester) async {
      await pumpApp(tester, household: withPerson());
      expect(find.text('Building your plan'), findsOneWidget);
      expect(find.text('Retirement year'), findsNothing);
      expect(find.text('1 of 7'), findsOneWidget);
    });

    testWidgets('the checklist says what was entered, not how many fields',
        (tester) async {
      await pumpApp(tester, household: spending(withPerson()));
      expect(find.textContaining('Alex · Colorado'), findsOneWidget);
      expect(find.textContaining('a year'), findsWidgets);
    });

    testWidgets('declaring readiness is what turns the numbers on',
        (tester) async {
      final container = await pumpApp(tester, household: spending(withPerson()));
      final progress = container.read(setupProgressProvider.notifier);
      for (final step in [
        SetupStep.work,
        SetupStep.accounts,
        SetupStep.owned,
        SetupStep.owed,
      ]) {
        progress.pass(step);
      }
      await tester.pump();
      expect(find.text('Retirement year'), findsNothing,
          reason: 'answered is not the same as ready');

      progress.declareReady();
      await tester.pump();
      expect(find.text('Retirement year'), findsOneWidget);
    });
  });

  group('the app opens where the work is', () {
    testWidgets('a plan being built lands on the checklist, not on a form',
        (tester) async {
      await pumpApp(tester, household: withPerson());
      expect(find.text('Building your plan'), findsWidgets);
      expect(find.text('Add a person'), findsNothing,
          reason: 'the Household form is a destination, not the front door');
      expect(find.text('Continue'), findsOneWidget);
    });

    testWidgets('the checklist is not shown twice at once', (tester) async {
      // The panel beside the content carries it everywhere else, so on the
      // screen that already shows it the panel says something shorter.
      await pumpApp(tester, household: withPerson());
      expect(find.text('Building your plan'), findsOneWidget);

      await tester.tap(find.text('Household').first);
      await tester.pump();
      expect(find.text('Building your plan'), findsOneWidget,
          reason: 'now it is the panel carrying it');
      expect(find.text('Add a person'), findsWidgets);
    });

    testWidgets('every screen is still reachable while building',
        (tester) async {
      await pumpApp(tester, household: withPerson());
      for (final screen in ['Household', 'Income', 'Accounts', 'Spending',
        'Property']) {
        await tester.tap(find.text(screen).first);
        await tester.pump();
      }
      expect(find.text('Property'), findsWidgets);
    });
  });

  group('housing, as reported', () {
    testWidgets('a house sold in 2046 with rent from 2046 reads as covered',
        (tester) async {
      // Reported: the timeline draws it right and the plan still says there is
      // nowhere to live.
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
              id: 'housing',
              householdId: 'h1',
              label: 'Housing',
              metaCategory: MetaCategory.housing),
        ],
        expenseItems: [
          ExpenseItem(
            id: 'rent',
            categoryId: 'housing',
            label: 'Rent',
            amount: Money.dollars(30000),
            frequency: ExpenseFrequency.annual,
            startYear: 2046,
          ),
        ],
      );
      final container = await pumpApp(tester, household: h);

      expect(container.read(setupProgressProvider).isDone(SetupStep.housing, h),
          isTrue,
          reason: 'the checklist has to agree with the timeline');
      expect(SetupStep.housing.summaryIn(h), 'covered for every year');
    });
  });

  group('rent filed in the wrong place', () {
    test('a line that reads like housing is spotted wherever it is', () {
      final h = withPerson().copyWith(
        expenseCategories: const [
          ExpenseCategory(
              id: 'misc',
              householdId: 'h1',
              label: 'Living',
              metaCategory: MetaCategory.misc),
        ],
        expenseItems: [
          ExpenseItem(
            id: 'rent',
            categoryId: 'misc',
            label: 'Rent',
            amount: Money.dollars(30000),
            frequency: ExpenseFrequency.annual,
          ),
        ],
      );
      expect(looksLikeHousing(h).single.id, 'rent');
      expect(housedIn(h, DateTime.now().year), isFalse,
          reason: 'the category is the check, which is the whole confusion');
    });

    test('and left alone once it is filed correctly', () {
      final h = withPerson().copyWith(
        expenseCategories: const [
          ExpenseCategory(
              id: 'housing',
              householdId: 'h1',
              label: 'Housing',
              metaCategory: MetaCategory.housing),
        ],
        expenseItems: [
          ExpenseItem(
            id: 'rent',
            categoryId: 'housing',
            label: 'Rent',
            amount: Money.dollars(30000),
            frequency: ExpenseFrequency.annual,
          ),
        ],
      );
      expect(looksLikeHousing(h), isEmpty);
      expect(housedIn(h, DateTime.now().year), isTrue);
    });

    test('a bill filed as shelter is caught, which is the worse mistake', () {
      // A misfiled rent shows a gap somebody can see. A misfiled electricity
      // bill quietly reports a roof that is not there.
      final h = withPerson().copyWith(
        expenseCategories: const [
          ExpenseCategory(
              id: 'shelter',
              householdId: 'h1',
              label: 'Rent or lodging',
              metaCategory: MetaCategory.housing),
        ],
        expenseItems: [
          ExpenseItem(
            id: 'power',
            categoryId: 'shelter',
            label: 'Electricity bill',
            amount: Money.dollars(2400),
            frequency: ExpenseFrequency.annual,
          ),
        ],
      );
      expect(looksLikeSupport(h).single.id, 'power');
      expect(housedIn(h, DateTime.now().year), isTrue,
          reason: 'which is exactly why it needs saying out loud');
    });

    test('real rent under shelter is left alone', () {
      final h = withPerson().copyWith(
        expenseCategories: const [
          ExpenseCategory(
              id: 'shelter',
              householdId: 'h1',
              label: 'Rent or lodging',
              metaCategory: MetaCategory.housing),
        ],
        expenseItems: [
          ExpenseItem(
            id: 'rent',
            categoryId: 'shelter',
            label: 'Rent',
            amount: Money.dollars(24000),
            frequency: ExpenseFrequency.annual,
          ),
        ],
      );
      expect(looksLikeSupport(h), isEmpty);
      expect(looksLikeHousing(h), isEmpty);
    });

    test('rental income is not mistaken for somewhere to live', () {
      // Why the check is a category and not a word search.
      final h = withPerson().copyWith(
        expenseCategories: const [
          ExpenseCategory(
              id: 'misc',
              householdId: 'h1',
              label: 'Living',
              metaCategory: MetaCategory.misc),
        ],
        expenseItems: [
          ExpenseItem(
            id: 'x',
            categoryId: 'misc',
            label: 'Groceries',
            amount: Money.dollars(9000),
            frequency: ExpenseFrequency.annual,
          ),
        ],
      );
      expect(looksLikeHousing(h), isEmpty);
    });
  });

  group('the setup path', () {
    testWidgets('detail can be opened and closed again', (tester) async {
      await pumpApp(tester, household: withPerson());
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('I have none of these'));
        await tester.pumpAndSettle();
      }
      // Housing has no "none of these": everybody lives somewhere.
      expect(find.text(SetupStep.housing.question), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Break it down instead'), findsOneWidget);

      await tester.tap(find.text('Break it down instead'));
      await tester.pumpAndSettle();
      expect(find.text('Go back to one number'), findsOneWidget,
          reason: 'a view somebody opens has to be a view they can close');

      await tester.tap(find.text('Go back to one number'));
      await tester.pumpAndSettle();
      expect(find.text('Break it down instead'), findsOneWidget);
    });

    testWidgets('opens on the step that is next', (tester) async {
      await pumpApp(tester, household: withPerson());
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Step 2 of 7'), findsOneWidget);
      expect(find.text(SetupStep.work.question), findsOneWidget);
    });

    testWidgets('"I have none of these" moves on and is remembered',
        (tester) async {
      final container = await pumpApp(tester, household: withPerson());
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('I have none of these'));
      await tester.pumpAndSettle();

      expect(container.read(setupProgressProvider).passed,
          contains(SetupStep.work));
      expect(find.text('Step 3 of 7'), findsOneWidget);
    });

    testWidgets('the door stays shut until the plan can answer', (tester) async {
      await pumpApp(tester, household: withPerson());
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      // Straight to the last gating step without answering anything.
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('I have none of these'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text(SetupStep.spending.question), findsOneWidget);

      final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Show me my plan'));
      expect(button.onPressed, isNull,
          reason: 'no spending entered, so there is nothing to show');

      // A shut door that will not say why is the worst kind. Two are open
      // here: nowhere to live, and nothing entered for what a year costs.
      expect(
          find.textContaining(
              'Still to answer: where you live and what a year costs'),
          findsOneWidget);
    });

    testWidgets('what is wrong is shown here, not on another screen',
        (tester) async {
      // A blocking finding used to be visible only from the home screen, so
      // the only signal inside the flow was a greyed-out button.
      final broken = withPerson().copyWith(
        incomeStreams: [
          IncomeStream(
            id: 'inc1',
            personId: 'nobody',
            label: 'Salary',
            kind: IncomeKind.w2Wages,
            grossAnnualAmount: Money.dollars(150000),
            isFicaSubject: true,
            isQualifiedBusinessIncome: false,
          ),
        ],
      );
      await pumpApp(tester, household: broken);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.textContaining('needs fixing'), findsOneWidget);
      expect(find.textContaining('has no owner'), findsOneWidget);
    });
  });
}
