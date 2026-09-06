import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

/// The invariant numbers reported, so a test can name §12 directly.
Set<int> numbersFrom(List<Finding> f) => f.map((x) => x.invariant).toSet();

void main() {
  test('a well-formed household reports nothing (§12)', () {
    expect(validateHousehold(simpleHousehold()), isEmpty);
  });

  group('membership (§12.1–4)', () {
    test('an expense with no category cannot reach a household', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        expenseItems: [
          const ExpenseItem(
            id: 'e1',
            categoryId: 'missing',
            label: 'Groceries',
            amount: Money(60000),
          ),
        ],
      );
      expect(numbersFrom(validateHousehold(h)), contains(1));
    });

    test('an account with no owner is caught', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [brokerage(personId: 'ghost')],
      );
      expect(numbersFrom(validateHousehold(h)), contains(2));
    });

    test('a person naming no tax unit is caught', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person(taxUnitId: 'nope')],
      );
      expect(numbersFrom(validateHousehold(h)), contains(3));
    });
  });

  group('allocation and contributions (§12.7–8)', () {
    test('weighted allocation must sum to 1.0', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [
          Account(
            id: 'a1',
            personId: 'p1',
            label: 'Brokerage',
            kind: AccountKind.taxableBrokerage,
            taxTreatment: TaxTreatment.taxable,
            limitFamily: LimitFamily.none,
            balance: Money.dollars(1000),
            isRestrictedPurpose: false,
            allocationMode: AllocationMode.weighted,
            allocationWeights: const [
              AllocationWeight(assetClassId: 'stocks', weight: 0.7),
              AllocationWeight(assetClassId: 'bonds', weight: 0.2),
            ],
            contribution: const Contribution(
              mode: ContributionMode.fixedAmount,
              value: 0,
            ),
          ),
        ],
      );
      expect(numbersFrom(validateHousehold(h)), contains(7));
    });

    test('a percentage of gross cannot draw on another person\'s income', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person(), person(id: 'p2', name: 'Sam')],
        incomeStreams: [salary(id: 'inc-2', personId: 'p2')],
        accounts: [
          traditional401k(
            contribution: const Contribution(
              mode: ContributionMode.percentOfGross,
              value: 0.10,
              contributionBaseStreamIds: ['inc-2'],
            ),
          ),
        ],
      );
      expect(numbersFrom(validateHousehold(h)), contains(8));
    });
  });

  group('accounting (§12.12–15)', () {
    test('a negative contribution would be an untaxed withdrawal', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [
          traditional401k(
            contribution: const Contribution(
              mode: ContributionMode.fixedAmount,
              value: -500000,
            ),
          ),
        ],
      );
      expect(numbersFrom(validateHousehold(h)), contains(12));
    });

    test('basis above balance warns rather than blocks, losses being real', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [brokerage(balance: 50000, basis: 60000)],
      );
      final findings = validateHousehold(h);
      expect(numbersFrom(findings), contains(13));
      expect(findings.hasBlocking, isFalse);
    });

    test('PMI cannot exceed the escrow it is part of', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        liabilities: [
          Liability(
            id: 'l1',
            householdId: 'h1',
            label: 'Mortgage',
            kind: LiabilityKind.mortgage,
            currentBalance: Money.dollars(300000),
            interestRate: 0.055,
            monthlyPayment: Money.dollars(2200),
            monthlyEscrowAmount: Money.dollars(400),
            monthlyPmiAmount: Money.dollars(500),
            originationDate: DateTime(2020, 3, 1),
            termMonths: 360,
          ),
        ],
      );
      expect(numbersFrom(validateHousehold(h)), contains(15));
    });
  });

  group('money that goes nowhere (§12.17–18)', () {
    test('an outflow must name the account it comes from', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        oneTimeEvents: [
          OneTimeEvent(
            id: 'ev1',
            householdId: 'h1',
            label: 'Truck',
            year: 2030,
            amount: Money.dollars(-40000),
          ),
        ],
      );
      expect(numbersFrom(validateHousehold(h)), contains(17));
    });

    test('a planned sale must say where the proceeds land', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        assets: [
          Asset(
            id: 'as1',
            householdId: 'h1',
            label: 'House',
            category: AssetCategory.primaryResidence,
            currentValue: Money.dollars(600000),
            costBasis: Money.dollars(400000),
            plannedSaleYear: 2040,
          ),
        ],
      );
      expect(numbersFrom(validateHousehold(h)), contains(18));
    });
  });

  group('attribution once a household files twice (§12.25)', () {
    test('one tax unit needs no attribution', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        assets: [
          Asset(
            id: 'as1',
            householdId: 'h1',
            label: 'Car',
            category: AssetCategory.vehicle,
            currentValue: Money.dollars(20000),
            costBasis: Money.dollars(30000),
          ),
        ],
      );
      expect(numbersFrom(validateHousehold(h)), isNot(contains(25)));
    });

    test('two tax units make an unattributed asset ambiguous', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit(), taxUnit(id: 'tu2')],
        people: [person(), person(id: 'p2', name: 'Sam', taxUnitId: 'tu2')],
        assets: [
          Asset(
            id: 'as1',
            householdId: 'h1',
            label: 'Car',
            category: AssetCategory.vehicle,
            currentValue: Money.dollars(20000),
            costBasis: Money.dollars(30000),
          ),
        ],
      );
      expect(numbersFrom(validateHousehold(h)), contains(25));
    });
  });

  group('limits and rates (§12.27–30)', () {
    test('claiming outside 62 to 70 is refused', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [
          person(
            socialSecurity: const SocialSecurityBenefit(
              personId: 'p1',
              estimatedMonthlyBenefitAtFra: Money(300000),
              claimingAge: 71,
            ),
          ),
        ],
      );
      expect(numbersFrom(validateHousehold(h)), contains(27));
    });

    test('a tax-advantaged account cannot be uncapped', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [
          Account(
            id: 'a1',
            personId: 'p1',
            label: 'Custom Roth',
            kind: AccountKind.rothIra,
            taxTreatment: TaxTreatment.roth,
            limitFamily: LimitFamily.none,
            balance: Money.dollars(1000),
            isRestrictedPurpose: false,
            contribution: const Contribution(
              mode: ContributionMode.fixedAmount,
              value: 0,
            ),
          ),
        ],
      );
      expect(numbersFrom(validateHousehold(h)), contains(29));
    });

    test('a waterfall with no terminal step strands the surplus', () {
      final a = Assumptions(
        taxYearId: 'us-2026',
        contributionWaterfall: [
          WaterfallStep.matchCapture,
          WaterfallStep.iraToLimit,
        ],
      );
      expect(numbersFrom(validateAssumptions(a)), contains(30));
    });

    test('a zero withdrawal rate would divide §8.1 by zero', () {
      const a = Assumptions(taxYearId: 'us-2026', safeWithdrawalRate: 0);
      expect(numbersFrom(validateAssumptions(a)), contains(28));
    });

    test('the default assumptions are valid', () {
      expect(validateAssumptions(const Assumptions(taxYearId: 'us-2026')),
          isEmpty);
    });
  });
}
