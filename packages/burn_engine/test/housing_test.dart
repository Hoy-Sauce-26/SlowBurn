import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

Asset home({int? soldIn}) => Asset(
      id: 'house',
      householdId: 'h1',
      label: 'House',
      category: AssetCategory.primaryResidence,
      currentValue: Money.dollars(600000),
      costBasis: Money.dollars(450000),
      plannedSaleYear: soldIn,
      saleProceedsAccountId: soldIn == null ? null : 'acct-taxable',
    );

Household living({
  Asset? asset,
  int? rentFrom,
  int? rentUntil,
  ExpensePhase phase = ExpensePhase.both,
  MetaCategory category = MetaCategory.housing,
}) =>
    Household(
      id: 'h1',
      taxUnits: [taxUnit()],
      people: [person()],
      assets: [?asset],
      expenseCategories: [
        ExpenseCategory(
          id: 'cat',
          householdId: 'h1',
          label: 'Housing',
          metaCategory: category,
        ),
      ],
      expenseItems: [
        if (rentFrom != null || rentUntil != null)
          ExpenseItem(
            id: 'rent',
            categoryId: 'cat',
            label: 'Rent',
            amount: Money.dollars(24000),
            frequency: ExpenseFrequency.annual,
            startYear: rentFrom,
            endYear: rentUntil,
            phase: phase,
          ),
      ],
    );

void main() {
  group('§3.7 everybody lives somewhere', () {
    test('owning the roof over your head counts', () {
      expect(housedIn(living(asset: home()), 2030), isTrue);
    });

    test('owning it outright still counts', () {
      // No mortgage left is not the same as no home. What it costs is escrow,
      // which §3.6 carries on charging.
      expect(housedIn(living(asset: home()), 2060), isTrue);
    });

    test('selling it leaves nowhere to live', () {
      final h = living(asset: home(soldIn: 2035));
      expect(housedIn(h, 2034), isTrue);
      expect(housedIn(h, 2035), isFalse,
          reason: 'the year of the sale is the year it stops being held');
      expect(housedIn(h, 2040), isFalse);
    });

    test('rent from the year of the sale covers it', () {
      final h = living(asset: home(soldIn: 2035), rentFrom: 2035);
      expect(housedIn(h, 2040), isTrue);
    });

    test('rent that runs out does not', () {
      final h = living(asset: home(soldIn: 2035), rentFrom: 2035,
          rentUntil: 2045);
      expect(housedIn(h, 2045), isTrue);
      expect(housedIn(h, 2046), isFalse);
    });

    test('rent that stops at retirement does not cover the years after it',
        () {
      final h = living(
        asset: home(soldIn: 2035),
        rentFrom: 2035,
        phase: ExpensePhase.preRetirementOnly,
      );
      expect(housedIn(h, 2040, retirementYear: 2038), isFalse);
      expect(housedIn(h, 2036, retirementYear: 2038), isTrue);
    });

    test('groceries are not shelter', () {
      final h = living(
        asset: home(soldIn: 2035),
        rentFrom: 2035,
        category: MetaCategory.food,
      );
      expect(housedIn(h, 2040), isFalse,
          reason: 'the category is the question, not the amount');
    });

    test('a household with neither is never housed', () {
      expect(housedIn(living(), 2030), isFalse);
    });
  });

  group('§3.7 the whole plan, not just this year', () {
    test('a sale ten years out is a gap ten years out', () {
      // The one that matters. Checking today says "housed", and the fourteen
      // years after the sale go unpriced.
      final h = living(asset: home(soldIn: 2036));
      expect(housedIn(h, 2026), isTrue, reason: 'today looks fine');

      final spans = housingTimeline(h, fromYear: 2026, toYear: 2050);
      expect(spans, hasLength(2));
      expect(spans.first.isGap, isFalse);
      expect(spans.first.toYear, 2035);
      expect(spans.last.isGap, isTrue);
      expect(spans.last.fromYear, 2036);
      expect(spans.last.years, 15);
    });

    test('rent from the sale year closes it', () {
      final h = living(asset: home(soldIn: 2036), rentFrom: 2036);
      final spans = housingTimeline(h, fromYear: 2026, toYear: 2050);
      expect(spans.where((s) => s.isGap), isEmpty);
    });

    test('rent that starts a year late leaves a one-year hole', () {
      final h = living(asset: home(soldIn: 2036), rentFrom: 2037);
      final spans = housingTimeline(h, fromYear: 2026, toYear: 2050);
      final gap = spans.singleWhere((s) => s.isGap);
      expect(gap.fromYear, 2036);
      expect(gap.toYear, 2036);
      expect(gap.years, 1);
    });

    test('a house bought later covers from the year it is bought', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        assets: [
          Asset(
            id: 'future',
            householdId: 'h1',
            label: 'House',
            category: AssetCategory.primaryResidence,
            currentValue: Money.dollars(500000),
            costBasis: Money.dollars(500000),
            acquisitionYear: 2032,
          ),
        ],
      );
      final spans = housingTimeline(h, fromYear: 2026, toYear: 2040);
      expect(spans.first.isGap, isTrue);
      expect(spans.first.toYear, 2031);
      expect(spans.last.isGap, isFalse);
      expect(spans.last.covers.single.owned, isTrue);
    });

    test('the spans say what is holding each one up', () {
      final h = living(asset: home(soldIn: 2036), rentFrom: 2036);
      final spans = housingTimeline(h, fromYear: 2026, toYear: 2040);
      expect(spans.first.covers.single.label, 'House');
      expect(spans.first.covers.single.owned, isTrue);
      expect(spans.last.covers.single.label, 'Rent');
      expect(spans.last.covers.single.owned, isFalse);
    });

    test('overlapping cover collapses into one span', () {
      // Owning and renting at once is one stretch of being housed, not two.
      final h = living(asset: home(), rentFrom: 2030, rentUntil: 2032);
      final spans = housingTimeline(h, fromYear: 2026, toYear: 2040);
      expect(spans.where((s) => s.isGap), isEmpty);
      expect(spans.length, greaterThan(1),
          reason: 'the cover changes even though the housing never lapses');
    });
  });

  group('§3.7 a bill is not a roof', () {
    test('utilities filed as housing support house nobody', () {
      // The failure that made this a second category: pay electricity to the
      // end of your life and the plan would have called you housed.
      final h = living(
        rentFrom: 2026,
        category: MetaCategory.housingSupport,
      );
      expect(housedIn(h, 2030), isFalse);
    });

    test('rent filed as housing does', () {
      expect(housedIn(living(rentFrom: 2026), 2030), isTrue);
    });

    test('a household with both is housed by the rent alone', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        expenseCategories: const [
          ExpenseCategory(
              id: 'shelter',
              householdId: 'h1',
              label: 'Rent or lodging',
              metaCategory: MetaCategory.housing),
          ExpenseCategory(
              id: 'bills',
              householdId: 'h1',
              label: 'Housing costs',
              metaCategory: MetaCategory.housingSupport),
        ],
        expenseItems: [
          ExpenseItem(
            id: 'rent',
            categoryId: 'shelter',
            label: 'Rent',
            amount: Money.dollars(24000),
            frequency: ExpenseFrequency.annual,
            endYear: 2040,
          ),
          ExpenseItem(
            id: 'power',
            categoryId: 'bills',
            label: 'Electricity',
            amount: Money.dollars(2400),
            frequency: ExpenseFrequency.annual,
          ),
        ],
      );
      expect(housedIn(h, 2040), isTrue);
      expect(housedIn(h, 2041), isFalse,
          reason: 'the rent ran out and the electricity is still on');
    });
  });

  group('§3.7 a bill belongs to a roof', () {
    Household withUpkeep({int? soldIn, Id? attachedTo}) => Household(
          id: 'h1',
          taxUnits: [taxUnit()],
          people: [person()],
          assets: [home(soldIn: soldIn)],
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
              housingId: attachedTo,
            ),
          ],
        );

    test('an attached cost stops when its home is sold', () {
      // Otherwise a plan pays four decades of property tax on a house it sold.
      final h = withUpkeep(soldIn: 2036, attachedTo: 'house');
      expect(housingCostStandsIn(h, h.expenseItems.single, 2035), isTrue);
      expect(housingCostStandsIn(h, h.expenseItems.single, 2036), isFalse);
    });

    test('an unattached one keeps its own dates', () {
      final h = withUpkeep(soldIn: 2036);
      expect(housingCostStandsIn(h, h.expenseItems.single, 2040), isTrue,
          reason: 'saying nothing is not the same as saying it stops');
    });

    test('a cost attached to rent follows the rent', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        expenseCategories: const [
          ExpenseCategory(
              id: 'shelter',
              householdId: 'h1',
              label: 'Rent or lodging',
              metaCategory: MetaCategory.housing),
          ExpenseCategory(
              id: 'bills',
              householdId: 'h1',
              label: 'Housing costs',
              metaCategory: MetaCategory.housingSupport),
        ],
        expenseItems: [
          ExpenseItem(
            id: 'rent',
            categoryId: 'shelter',
            label: 'Rent',
            amount: Money.dollars(24000),
            frequency: ExpenseFrequency.annual,
            endYear: 2040,
          ),
          ExpenseItem(
            id: 'contents',
            categoryId: 'bills',
            label: "Renter's insurance",
            amount: Money.dollars(300),
            frequency: ExpenseFrequency.annual,
            housingId: 'rent',
          ),
        ],
      );
      final contents = h.expenseItems.last;
      expect(housingCostStandsIn(h, contents, 2040), isTrue);
      expect(housingCostStandsIn(h, contents, 2041), isFalse);
    });

    test('a reference that has gone stale keeps the cost rather than losing it',
        () {
      final h = withUpkeep(attachedTo: 'a-house-that-was-deleted');
      expect(housingCostStandsIn(h, h.expenseItems.single, 2040), isTrue,
          reason: 'dropping spending because a link broke would shrink a '
              'plan silently');
    });
  });
}
