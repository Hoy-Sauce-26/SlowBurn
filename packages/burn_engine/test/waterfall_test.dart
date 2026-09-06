import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

final taxYear =
    parseTaxYear(File('../../assets/tax_years/2026.json').readAsStringSync());
const year = 2026;

Account cashBuffer({num balance = 5000, double months = 6}) => Account(
      id: 'cash',
      personId: 'p1',
      label: 'Savings',
      kind: AccountKind.cashSavings,
      taxTreatment: TaxTreatment.taxable,
      limitFamily: LimitFamily.none,
      balance: Money.dollars(balance),
      costBasis: Money.dollars(balance),
      isRestrictedPurpose: false,
      targetBalanceMonths: months,
      contribution:
          const Contribution(mode: ContributionMode.fixedAmount, value: 0),
    );

Account ira({num balance = 20000}) => Account(
      id: 'ira',
      personId: 'p1',
      label: 'Roth IRA',
      kind: AccountKind.rothIra,
      taxTreatment: TaxTreatment.roth,
      limitFamily: LimitFamily.ira,
      balance: Money.dollars(balance),
      isRestrictedPurpose: false,
      contribution:
          const Contribution(mode: ContributionMode.fixedAmount, value: 0),
    );

Liability card({num balance = 8000, Rate rate = 0.22}) => Liability(
      id: 'card',
      householdId: 'h1',
      label: 'Card',
      kind: LiabilityKind.creditCard,
      currentBalance: Money.dollars(balance),
      interestRate: rate,
      monthlyPayment: Money.dollars(300),
      originationDate: DateTime(2024, 1, 1),
      termMonths: 60,
    );

Allocation allocate(
  Household h, {
  required num surplus,
  Assumptions? assumptions,
  Map<Id, Money> already = const {},
  num annualExpenses = 60000,
  bool earning = true,
}) =>
    runAllocationSweep(
      h,
      assumptions: assumptions ?? const Assumptions(taxYearId: 'us-2026'),
      taxYear: taxYear,
      accounts: {for (final a in h.accounts) a.id: AccountState(a)},
      liabilities: {for (final l in h.liabilities) l.id: LiabilityState(l)},
      alreadyContributed: already,
      earnedIncome: {
        for (final p in h.people)
          p.id: earning ? Money.dollars(100000) : Money.zero,
      },
      surplus: Money.dollars(surplus),
      annualExpenses: Money.dollars(annualExpenses),
      year: year,
      currentYear: year,
    );

void main() {
  group('§4.4.4 the waterfall', () {
    test('fills the IRA, tops the buffer, and brokerages the rest', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [ira(), cashBuffer(balance: 5000), brokerageIn()],
      );
      final a = allocate(h, surplus: 60000, annualExpenses: 60000);

      final iraLimit = taxYear.contributionLimits[LimitFamily.ira]!.annual!;
      expect(a.toAccounts['ira'], iraLimit);
      expect(a.toAccounts['cash'], Money.dollars(30000 - 5000),
          reason: 'six months of a 60,000 cost of living, less what is there');
      expect(a.remaining, Money.zero, reason: 'the brokerage takes the rest');
      expect(a.spent, Money.dollars(60000));
    });

    test('a step is capped by remaining room, not the whole limit', () {
      // A user already contributing does not get the account topped up to the
      // full limit again (§4.4.1).
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [ira()],
      );
      final iraLimit = taxYear.contributionLimits[LimitFamily.ira]!.annual!;
      final a = allocate(h,
          surplus: 60000, already: {'ira': Money.dollars(4000)});
      expect(a.toAccounts['ira'], iraLimit - Money.dollars(4000));
    });

    test('a funded buffer stops competing', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [cashBuffer(balance: 40000), brokerageIn()],
      );
      final a = allocate(h, surplus: 20000, annualExpenses: 60000);
      expect(a.toAccounts['cash'], isNull);
    });

    test('a retirement step needs earned income behind it', () {
      // A retired year turning positive on an RMD would otherwise route the
      // surplus into an IRA the household cannot legally fund.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [ira(), brokerageIn()],
      );
      final working = allocate(h, surplus: 20000);
      final retired = allocate(h, surplus: 20000, earning: false);
      expect(working.toAccounts['ira']!.isPositive, isTrue);
      expect(retired.toAccounts['ira'], isNull);
      expect(retired.toAccounts['acct-taxable'], Money.dollars(20000),
          reason: 'the brokerage carries no such requirement');
    });

    test('high-interest debt is paid highest real rate first', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [brokerageIn()],
        liabilities: [
          card(balance: 8000, rate: 0.22),
          Liability(
            id: 'student',
            householdId: 'h1',
            label: 'Student',
            kind: LiabilityKind.studentLoan,
            currentBalance: Money.dollars(20000),
            interestRate: 0.11,
            monthlyPayment: Money.dollars(250),
            originationDate: DateTime(2018, 9, 1),
            termMonths: 120,
          ),
        ],
      );
      final a = allocate(h, surplus: 10000);
      expect(a.toDebt['card'], Money.dollars(8000),
          reason: 'the 22% card clears first');
      expect(a.toDebt['student'], Money.dollars(2000),
          reason: 'what is left reaches the next-highest rate');
    });

    test('the threshold is real, so a 7% loan is below a 6% bar', () {
      // Paying down debt is an investment decision, and both sides need the
      // same units (§3.9). At 2.5% inflation, 7% nominal is 4.4% real.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [brokerageIn()],
        liabilities: [card(balance: 8000, rate: 0.07)],
      );
      expect(allocate(h, surplus: 10000).toDebt, isEmpty);

      // The same loan clears the bar once inflation is low enough.
      final lowInflation = allocate(
        h,
        surplus: 10000,
        assumptions:
            const Assumptions(taxYearId: 'us-2026', generalInflationRate: 0.0),
      );
      expect(lowInflation.toDebt['card'], Money.dollars(8000));
    });

    test('debt below the threshold is left alone', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [brokerageIn()],
        liabilities: [card(balance: 8000, rate: 0.03)],
      );
      final a = allocate(h, surplus: 10000);
      expect(a.toDebt, isEmpty);
    });

    test('a partly funded step splits pro rata by remaining room', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [
          person(),
          person(id: 'p2', name: 'Sam'),
        ],
        accounts: [
          ira(),
          Account(
            id: 'ira2',
            personId: 'p2',
            label: 'Roth IRA',
            kind: AccountKind.rothIra,
            taxTreatment: TaxTreatment.roth,
            limitFamily: LimitFamily.ira,
            balance: Money.dollars(20000),
            isRestrictedPurpose: false,
            contribution: const Contribution(
                mode: ContributionMode.fixedAmount, value: 0),
          ),
        ],
      );
      final a = allocate(h, surplus: 5000);
      expect(a.anyStepPartiallyFunded, isTrue);
      expect(a.toAccounts['ira'], a.toAccounts['ira2'],
          reason: 'equal room splits evenly');
      expect(sumMoney(a.toAccounts.values), Money.dollars(5000));
    });

    test('a scenario omitting the saving steps banks the surplus (§9.3)', () {
      // Coast FIRE: stopping the committed contributions alone would hand the
      // same money straight back through the waterfall.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [ira(), brokerageIn()],
      );
      final coasting = allocate(
        h,
        surplus: 20000,
        assumptions: const Assumptions(
          taxYearId: 'us-2026',
          contributionWaterfall: [
            WaterfallStep.highInterestDebt,
            WaterfallStep.cashBufferToTarget,
            WaterfallStep.taxableBrokerage,
          ],
        ),
      );
      expect(coasting.toAccounts['ira'], isNull);
      expect(coasting.toAccounts['acct-taxable'], Money.dollars(20000));
    });
  });

  group('§4.4.2 sweep 1 reserves for what outranks it', () {
    test('debt ranked above the 401(k) is reserved before the election', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [traditional401k(), brokerageIn()],
        liabilities: [card(balance: 8000, rate: 0.22)],
      );
      Allocation elect(List<WaterfallStep> order) => runElectionSweep(
            h,
            assumptions:
                Assumptions(taxYearId: 'us-2026', contributionWaterfall: order),
            taxYear: taxYear,
            accounts: {for (final a in h.accounts) a.id: AccountState(a)},
            liabilities: {
              for (final l in h.liabilities) l.id: LiabilityState(l)
            },
            earnedIncome: {'p1': Money.dollars(100000)},
            projectedSurplus: Money.dollars(15000),
            annualExpenses: Money.dollars(60000),
            year: year,
          );

      final debtFirst = elect([
        WaterfallStep.highInterestDebt,
        WaterfallStep.electiveDeferralToLimit,
        WaterfallStep.taxableBrokerage,
      ]);
      final planFirst = elect([
        WaterfallStep.electiveDeferralToLimit,
        WaterfallStep.highInterestDebt,
        WaterfallStep.taxableBrokerage,
      ]);

      expect(debtFirst.toAccounts['acct-401k'], Money.dollars(7000),
          reason: '15,000 less the 8,000 reserved for the card');
      expect(planFirst.toAccounts['acct-401k'], Money.dollars(15000),
          reason: 'ranked first, the election takes it all');
    });
  });
}
