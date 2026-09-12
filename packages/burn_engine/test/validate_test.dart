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

  group('an allocation that is not there', () {
    test('an account invested in a missing class is caught', () {
      // It blends to a zero return, so the account silently stops growing.
      // Found by a fixture naming a class the defaults do not have.
      expect(
          numbersFrom(validateHousehold(_invested('stocks'),
              assetClassIds: {'usStocks'})),
          contains(12));
    });

    test('and left alone when the class is there', () {
      expect(validateHousehold(_invested('stocks'),
          assetClassIds: {'stocks'}), isEmpty);
    });

    test('a caller that does not know the classes is not guessed at', () {
      expect(validateHousehold(_invested('stocks')), isEmpty);
    });
  });

  group('a share of nothing', () {
    test('an account nobody pays into needs no salary behind it', () {
      // What it looked like in the app: a spouse's old TSP, dormant, with no
      // employer and no income, reported as "a percentage of nothing" and
      // blocking the whole projection over a contribution of zero.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [
          Account(
            id: 'tsp',
            personId: 'p1',
            label: "Masha's TSP",
            kind: AccountKind.traditionalTsp,
            taxTreatment: TaxTreatment.taxDeferred,
            limitFamily: LimitFamily.electiveDeferral,
            balance: Money.dollars(90000),
            isRestrictedPurpose: false,
            assetAllocationId: 'stocks',
            contribution: const Contribution(
              mode: ContributionMode.percentOfGross,
              value: 0,
            ),
          ),
        ],
      );
      expect(validateHousehold(h), isEmpty);
    });

    test('a real percentage still needs one', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [
          Account(
            id: 'tsp',
            personId: 'p1',
            label: 'TSP',
            kind: AccountKind.traditionalTsp,
            taxTreatment: TaxTreatment.taxDeferred,
            limitFamily: LimitFamily.electiveDeferral,
            balance: Money.dollars(90000),
            isRestrictedPurpose: false,
            assetAllocationId: 'stocks',
            contribution: const Contribution(
              mode: ContributionMode.percentOfGross,
              value: 10,
            ),
          ),
        ],
      );
      expect(numbersFrom(validateHousehold(h)), contains(8));
    });
  });

  group('accounting (§12.12–14)', () {
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

    test('a holding that has fallen in value is not worth mentioning', () {
      // Shares go down. Basis above balance is an unrealised loss, which §6.3
      // already clamps to a zero gain, so saying so only teaches the user
      // that the app does not know what a market is.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [brokerage(balance: 50000, basis: 60000)],
      );
      expect(validateHousehold(h), isEmpty);
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
      expect(numbersFrom(validateHousehold(h)), contains(14));
    });
  });

  group('money that goes nowhere (§12.16–17)', () {
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
      expect(numbersFrom(validateHousehold(h)), contains(16));
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
      expect(numbersFrom(validateHousehold(h)), contains(17));
    });
  });

  group('attribution once a household files twice (§12.24)', () {
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
      expect(numbersFrom(validateHousehold(h)), isNot(contains(24)));
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
      expect(numbersFrom(validateHousehold(h)), contains(24));
    });
  });

  group('limits and rates (§12.26–29)', () {
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
      expect(numbersFrom(validateHousehold(h)), contains(26));
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
      expect(numbersFrom(validateHousehold(h)), contains(28));
    });

    test('a waterfall with no terminal step strands the surplus', () {
      final a = Assumptions(
        taxYearId: 'us-2026',
        contributionWaterfall: [
          WaterfallStep.matchCapture,
          WaterfallStep.iraToLimit,
        ],
      );
      expect(numbersFrom(validateAssumptions(a)), contains(29));
    });

    test('a zero withdrawal rate would divide §8.1 by zero', () {
      const a = Assumptions(taxYearId: 'us-2026', safeWithdrawalRate: 0);
      expect(numbersFrom(validateAssumptions(a)), contains(27));
    });

    test('the default assumptions are valid', () {
      expect(validateAssumptions(const Assumptions(taxYearId: 'us-2026')),
          isEmpty);
    });
  });
}

/// A household holding one account invested in [classId].
Household _invested(Id classId) => Household(
      id: 'h1',
      taxUnits: [taxUnit()],
      people: [person()],
      accounts: [
        Account(
          id: 'acct',
          personId: 'p1',
          label: 'Brokerage',
          kind: AccountKind.taxableBrokerage,
          taxTreatment: TaxTreatment.taxable,
          limitFamily: LimitFamily.none,
          balance: Money.dollars(100000),
          costBasis: Money.dollars(60000),
          isRestrictedPurpose: false,
          assetAllocationId: classId,
          contribution:
              const Contribution(mode: ContributionMode.fixedAmount, value: 0),
        ),
      ],
    );
