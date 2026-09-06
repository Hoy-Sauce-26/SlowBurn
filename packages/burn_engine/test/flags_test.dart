import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

final taxYear =
    parseTaxYear(File('../../assets/tax_years/2026.json').readAsStringSync());
final asOf = DateTime(2026, 1, 1);

Set<String> flagsFor(Household h, {int? retirementYear, int year = 2026}) {
  final p = project(
    h,
    assumptions: const Assumptions(taxYearId: 'us-2026'),
    taxYear: taxYear,
    assetClasses: assetClasses(),
    asOfDate: asOf,
    retirementYear: retirementYear,
  );
  return p.yearOf(year)!.flags;
}

ExpenseCategory cat(String id, MetaCategory meta) => ExpenseCategory(
      id: id,
      householdId: 'h1',
      label: id,
      metaCategory: meta,
    );

void main() {
  group('flags the engine raises about its own limits', () {
    test('qbiLimitNotModeled where the real limits would bite', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [
          IncomeStream(
            id: 'se1',
            personId: 'p1',
            label: 'Consulting',
            kind: IncomeKind.selfEmployment,
            grossAnnualAmount: Money.dollars(400000),
            isFicaSubject: false,
            isQualifiedBusinessIncome: true,
            isSpecifiedServiceBusiness: true,
          ),
        ],
      );
      expect(flagsFor(h), contains('qbiLimitNotModeled'));
    });

    test('earningsTestNotModeled where a benefit is claimed early and earned',
        () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [
          person(
            birthYear: 1962,
            socialSecurity: SocialSecurityBenefit(
              personId: 'p1',
              estimatedMonthlyBenefitAtFra: Money.dollars(2200),
              claimingAge: 63,
            ),
          ),
        ],
        incomeStreams: [salary(pay: 80000)],
      );
      expect(flagsFor(h), contains('earningsTestNotModeled'));
    });

    test('hsaContributionsStoppedAtMedicare past 65', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [
          Person(
            id: 'p1',
            displayName: 'Alex',
            birthDate: DateTime(1958, 3, 1),
            taxUnitId: 'tu1',
            hsaCoverage: const [
              HsaCoverageEntry(fromYear: 2000, tier: HsaTier.self)
            ],
          ),
        ],
        incomeStreams: [salary(pay: 90000)],
        accounts: [
          Account(
            id: 'hsa',
            personId: 'p1',
            label: 'HSA',
            kind: AccountKind.hsa,
            taxTreatment: TaxTreatment.hsaTriple,
            limitFamily: LimitFamily.hsa,
            balance: Money.dollars(30000),
            isRestrictedPurpose: false,
            assetAllocationId: 'stocks',
            contribution: const Contribution(
              mode: ContributionMode.fixedAmount,
              value: 200000,
              reducesFederalTaxableIncome: true,
              reducesFicaWages: true,
            ),
          ),
        ],
      );
      expect(flagsFor(h), contains('hsaContributionsStoppedAtMedicare'));
    });

    test('unvestedMatchAtRisk where the match has a cliff', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        employers: const [
          Employer(id: 'emp', householdId: 'h1', label: 'Acme')
        ],
        incomeStreams: [salary(pay: 120000, employerId: 'emp')],
        accounts: [
          traditional401k(
            employerId: 'emp',
            contribution: const Contribution(
              mode: ContributionMode.fixedAmount,
              value: 1000000,
              reducesFederalTaxableIncome: true,
              employerMatch: EmployerMatch(
                formula: MatchFormula.percentOfContribution,
                matchRate: 0.5,
                matchLimitPercentOfSalary: 0.06,
                vestingSchedule: CliffVesting(3),
              ),
            ),
          ),
        ],
      );
      expect(flagsFor(h), contains('unvestedMatchAtRisk'));
    });

    test('an immediate schedule puts nothing at risk', () {
      expect(matchAtRisk(const ImmediateVesting()), isFalse);
      expect(matchAtRisk(const CliffVesting(3)), isTrue);
      expect(matchAtRisk(null), isFalse);
    });

    test('filingStatusNoLongerQualifies once the dependents age out', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit(filingStatus: FilingStatus.headOfHousehold)],
        people: [person()],
        incomeStreams: [salary(pay: 90000)],
      );
      expect(flagsFor(h), contains('filingStatusNoLongerQualifies'));
    });

    test('acaMagiBelowSubsidyFloor where the real program pays nothing', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [
          Person(
            id: 'p1',
            displayName: 'Alex',
            birthDate: DateTime(1975, 6, 1),
            taxUnitId: 'tu1',
            employerHealthCoverageEndYear: 2020,
          ),
        ],
        accounts: [brokerageIn(balance: 20000, basis: 20000)],
      );
      expect(flagsFor(h), contains('acaMagiBelowSubsidyFloor'));
    });

    test('payoffLeavesResidualEscrow once the loan is gone', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 150000)],
        liabilities: [
          Liability(
            id: 'mtg',
            householdId: 'h1',
            label: 'Mortgage',
            kind: LiabilityKind.mortgage,
            currentBalance: Money.dollars(1000),
            interestRate: 0.05,
            monthlyPayment: Money.dollars(2000),
            monthlyEscrowAmount: Money.dollars(400),
            originationDate: DateTime(2010, 1, 1),
            termMonths: 360,
          ),
        ],
      );
      expect(flagsFor(h, year: 2028),
          contains('payoffLeavesResidualEscrow'));
    });

    test('possibleDoubleCount where an expense restates a loan payment', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        expenseCategories: [cat('housing', MetaCategory.housing)],
        expenseItems: [
          const ExpenseItem(
            id: 'e1',
            categoryId: 'housing',
            label: 'Mortgage payment',
            amount: Money(240000),
          ),
        ],
      );
      expect(doubleCountFlags(h), contains('possibleDoubleCount'));
    });

    test('a health premium line is caught too', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        expenseCategories: [cat('health', MetaCategory.health)],
        expenseItems: [
          const ExpenseItem(
            id: 'e1',
            categoryId: 'health',
            label: 'Insurance premium',
            amount: Money(90000),
          ),
        ],
      );
      expect(doubleCountFlags(h), contains('possibleDoubleCount'));
    });

    test('an ordinary grocery line is not', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        expenseCategories: [cat('food', MetaCategory.food)],
        expenseItems: [
          const ExpenseItem(
            id: 'e1',
            categoryId: 'food',
            label: 'Groceries',
            amount: Money(90000),
          ),
        ],
      );
      expect(doubleCountFlags(h), isEmpty);
    });
  });

  group('§8.1 swrHorizonMismatch', () {
    test('a long retirement at 4% is flagged', () {
      expect(
          swrHorizonMismatch(
              const Assumptions(taxYearId: 'x', safeWithdrawalRate: 0.04), 50),
          isTrue);
    });

    test('the same horizon at 3.25% is not', () {
      expect(
          swrHorizonMismatch(
              const Assumptions(taxYearId: 'x', safeWithdrawalRate: 0.0325),
              50),
          isFalse);
    });

    test('a short retirement at 4% is fine', () {
      expect(
          swrHorizonMismatch(
              const Assumptions(taxYearId: 'x', safeWithdrawalRate: 0.04), 25),
          isFalse);
    });
  });

  group('§8.4.1 the assumed rollover', () {
    test('a designated Roth balance moves to the Roth IRA at retirement', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person(birthYear: 1970)],
        incomeStreams: [salary(pay: 150000, endYear: 2029)],
        accounts: [
          Account(
            id: 'roth401k',
            personId: 'p1',
            label: 'Roth 401(k)',
            kind: AccountKind.roth401k,
            taxTreatment: TaxTreatment.roth,
            limitFamily: LimitFamily.electiveDeferral,
            balance: Money.dollars(300000),
            rothContributionBasis: Money.dollars(180000),
            isRestrictedPurpose: false,
            assetAllocationId: 'stocks',
            contribution: const Contribution(
                mode: ContributionMode.fixedAmount, value: 0),
          ),
          Account(
            id: 'rothira',
            personId: 'p1',
            label: 'Roth IRA',
            kind: AccountKind.rothIra,
            taxTreatment: TaxTreatment.roth,
            limitFamily: LimitFamily.ira,
            balance: Money.dollars(50000),
            rothContributionBasis: Money.dollars(40000),
            isRestrictedPurpose: false,
            assetAllocationId: 'stocks',
            contribution: const Contribution(
                mode: ContributionMode.fixedAmount, value: 0),
          ),
        ],
      );
      final p = project(
        h,
        assumptions: const Assumptions(taxYearId: 'us-2026'),
        taxYear: taxYear,
        assetClasses: assetClasses(),
        asOfDate: asOf,
        retirementYear: 2030,
      );
      final at = p.yearOf(2030)!;
      expect(at.flags, contains('rothRolloverAssumed'));
      expect(at.accountBalances['roth401k'], Money.zero);
      expect(at.accountBalances['rothira']! > Money.dollars(300000), isTrue,
          reason: 'the balance moved, and without it workplace Roth basis '
              'would be permanently unreachable');
    });
  });

  group('§8.4.4 the MAGI ceiling', () {
    Household earlyRetiree({required num traditional, required num cash}) =>
        Household(
          id: 'h1',
          taxUnits: [taxUnit()],
          people: [
            Person(
              id: 'p1',
              displayName: 'Alex',
              birthDate: DateTime(1975, 6, 1),
              taxUnitId: 'tu1',
              employerHealthCoverageEndYear: 2025,
            ),
          ],
          accounts: [
            traditional401k(balance: traditional),
            Account(
              id: 'cash',
              personId: 'p1',
              label: 'Savings',
              kind: AccountKind.cashSavings,
              taxTreatment: TaxTreatment.taxable,
              limitFamily: LimitFamily.none,
              balance: Money.dollars(cash),
              costBasis: Money.dollars(cash),
              isRestrictedPurpose: false,
              assetAllocationId: 'cash',
              contribution: const Contribution(
                  mode: ContributionMode.fixedAmount, value: 0),
            ),
          ],
          expenseCategories: [cat('living', MetaCategory.misc)],
          expenseItems: [
            const ExpenseItem(
              id: 'e1',
              categoryId: 'living',
              label: 'Living',
              amount: Money(6000000),
            ),
          ],
        );

    test('non-MAGI money is spent first, so the ceiling holds', () {
      // Plenty of cash: the year is funded without touching the 401(k), and
      // the subsidy survives.
      expect(
        flagsFor(earlyRetiree(traditional: 900000, cash: 400000),
            retirementYear: 2026),
        isNot(contains('magiCeilingBreached')),
      );
    });

    test('the ceiling is breached rather than under-funding the year', () {
      // Almost no cash, so the gap has to come from the 401(k) and the credit
      // is lost. Under-funding the year would be the wrong answer.
      expect(
        flagsFor(earlyRetiree(traditional: 2000000, cash: 2000),
            retirementYear: 2026),
        contains('magiCeilingBreached'),
      );
    });

    test('no ceiling applies once nobody buys their own cover', () {
      expect(
        magiCeilingFor(
          household: earlyRetiree(traditional: 900000, cash: 4000),
          assumptions: const Assumptions(taxYearId: 'us-2026'),
          taxYear: taxYear,
          magiSoFar: Money.zero,
          year: 2050,
        ),
        isNull,
        reason: 'past 65 the household is on Medicare',
      );
    });
  });

  group('§4.4.4 an over-large election', () {
    test('is flagged rather than quietly smoothed away', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 60000)],
        accounts: [
          traditional401k(
            balance: 10000,
            contribution: const Contribution(
              mode: ContributionMode.percentOfGross,
              value: 0.20,
              contributionBaseStreamIds: ['inc-1'],
              reducesFederalTaxableIncome: true,
            ),
          ),
          Account(
            id: 'cash',
            personId: 'p1',
            label: 'Savings',
            kind: AccountKind.cashSavings,
            taxTreatment: TaxTreatment.taxable,
            limitFamily: LimitFamily.none,
            balance: Money.dollars(50000),
            costBasis: Money.dollars(50000),
            isRestrictedPurpose: false,
            assetAllocationId: 'cash',
            contribution: const Contribution(
                mode: ContributionMode.fixedAmount, value: 0),
          ),
        ],
        expenseCategories: [cat('living', MetaCategory.misc)],
        expenseItems: [
          // A 20% deferral plus this cost of living leaves the year negative
          // once tax is real, and the deferral has already been withheld.
          const ExpenseItem(
            id: 'e1',
            categoryId: 'living',
            label: 'Living',
            amount: Money(5000000),
          ),
        ],
      );
      expect(flagsFor(h), contains('electionExceededRealizedSurplus'));
    });
  });
}
