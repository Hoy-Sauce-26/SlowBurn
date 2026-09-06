import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

final taxYear =
    parseTaxYear(File('../../assets/tax_years/2026.json').readAsStringSync());
const year = 2026;

YearResult solve(
  Household h, {
  Assumptions? assumptions,
  Map<Id, Money> proposed = const {},
  int? retirementYear,
}) =>
    solveYear(
      h,
      assumptions: assumptions ?? const Assumptions(taxYearId: 'us-2026'),
      taxYear: taxYear,
      assetClasses: assetClasses(),
      year: year,
      currentYear: year,
      retirementYear: retirementYear,
      proposedContributions: proposed,
    );

ExpenseCategory groceries() => const ExpenseCategory(
      id: 'cat-food',
      householdId: 'h1',
      label: 'Food',
      metaCategory: MetaCategory.food,
    );

void main() {
  group('§4.4 the year balances', () {
    test('net surplus is income less everything the household spent', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 150000)],
        expenseCategories: [groceries()],
        expenseItems: [
          const ExpenseItem(
            id: 'e1',
            categoryId: 'cat-food',
            label: 'Living',
            amount: Money(6000000),
          ),
        ],
      );
      final r = solve(h);
      final c = r.cashFlow;
      expect(c.grossIncome, Money.dollars(150000));
      expect(c.annualExpenses,
          c.expenseItemTotal + c.debtService + c.healthInsurance);
      expect(
        c.netSurplus,
        c.grossIncome +
            c.oneTimeNet +
            c.education529Draw -
            c.payrollDeductions -
            c.committedContribs -
            c.totalTaxOwed -
            c.annualExpenses,
      );
      expect(c.netSurplus.isPositive, isTrue);
    });

    test('in-account investment income never reaches gross income', () {
      // It never leaves the account, so counting it as inflow would let the
      // waterfall reinvest dollars that are already invested (§4.4).
      final withAccount = solve(Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 100000)],
        accounts: [brokerageIn(balance: 500000, basis: 500000)],
      ));
      expect(withAccount.cashFlow.grossIncome, Money.dollars(100000));
      expect(withAccount.incomes.first.inAccountInvestmentIncome.isPositive,
          isTrue, reason: 'it is taxed, just not received');
    });

    test('a restricted balance is spent on the thing that restricts it', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 120000)],
        accounts: [
          Account(
            id: '529',
            personId: 'p1',
            label: 'College',
            kind: AccountKind.education529,
            taxTreatment: TaxTreatment.educationTaxFree,
            limitFamily: LimitFamily.education,
            balance: Money.dollars(80000),
            isRestrictedPurpose: true,
            contribution:
                const Contribution(mode: ContributionMode.fixedAmount, value: 0),
          ),
        ],
        expenseCategories: [
          const ExpenseCategory(
            id: 'cat-edu',
            householdId: 'h1',
            label: 'Tuition',
            metaCategory: MetaCategory.education,
          ),
        ],
        expenseItems: [
          const ExpenseItem(
            id: 'e1',
            categoryId: 'cat-edu',
            label: 'Tuition',
            amount: Money(3000000),
          ),
        ],
      );
      expect(solve(h).cashFlow.education529Draw, Money.dollars(30000));
    });

    test('the draw is capped by the balance, and the rest falls through', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 120000)],
        accounts: [
          Account(
            id: '529',
            personId: 'p1',
            label: 'College',
            kind: AccountKind.education529,
            taxTreatment: TaxTreatment.educationTaxFree,
            limitFamily: LimitFamily.education,
            balance: Money.dollars(5000),
            isRestrictedPurpose: true,
            contribution:
                const Contribution(mode: ContributionMode.fixedAmount, value: 0),
          ),
        ],
        expenseCategories: [
          const ExpenseCategory(
            id: 'cat-edu',
            householdId: 'h1',
            label: 'Tuition',
            metaCategory: MetaCategory.education,
          ),
        ],
        expenseItems: [
          const ExpenseItem(
            id: 'e1',
            categoryId: 'cat-edu',
            label: 'Tuition',
            amount: Money(3000000),
          ),
        ],
      );
      expect(solve(h).cashFlow.education529Draw, Money.dollars(5000));
    });
  });

  group('§3.4 limits', () {
    test('one elective limit is shared across two employers\' plans', () {
      // Someone who changed jobs mid-year holds two 401(k)s and gets one limit
      // between them, split pro rata.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        employers: const [
          Employer(id: 'emp-a', householdId: 'h1', label: 'Acme'),
          Employer(id: 'emp-b', householdId: 'h1', label: 'Globex'),
        ],
        incomeStreams: [
          salary(id: 'i1', pay: 100000, employerId: 'emp-a'),
          salary(id: 'i2', pay: 100000, employerId: 'emp-b'),
        ],
        accounts: [
          traditional401k(
            id: 'k1',
            employerId: 'emp-a',
            contribution: const Contribution(
              mode: ContributionMode.fixedAmount,
              value: 2000000,
              reducesFederalTaxableIncome: true,
            ),
          ),
          traditional401k(
            id: 'k2',
            employerId: 'emp-b',
            contribution: const Contribution(
              mode: ContributionMode.fixedAmount,
              value: 2000000,
              reducesFederalTaxableIncome: true,
            ),
          ),
        ],
      );
      final r = solve(h);
      final total = sumMoney(r.contributions.map((c) => c.employee));
      final limit =
          taxYear.contributionLimits[LimitFamily.electiveDeferral]!.annual!;
      expect(total, limit, reason: 'one limit, not two');
      expect(r.contributions.every((c) => c.limitExceeded), isTrue);
      expect(r.contributions[0].employee, r.contributions[1].employee,
          reason: 'equal asks split evenly');
    });

    test('an IRA and a Roth IRA share one limit', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 60000)],
        accounts: [
          for (final (id, kind, treatment) in [
            ('t-ira', AccountKind.traditionalIra, TaxTreatment.taxDeferred),
            ('r-ira', AccountKind.rothIra, TaxTreatment.roth),
          ])
            Account(
              id: id,
              personId: 'p1',
              label: id,
              kind: kind,
              taxTreatment: treatment,
              limitFamily: LimitFamily.ira,
              balance: Money.dollars(10000),
              isRestrictedPurpose: false,
              contribution: const Contribution(
                mode: ContributionMode.fixedAmount,
                value: 600000,
              ),
            ),
        ],
      );
      final r = solve(h);
      expect(sumMoney(r.contributions.map((c) => c.employee)),
          taxYear.contributionLimits[LimitFamily.ira]!.annual!);
    });

    test('catch-up raises the limit for an older person', () {
      Money contributedAt(int birthYear) {
        final h = Household(
          id: 'h1',
          taxUnits: [taxUnit()],
          people: [person(birthYear: birthYear)],
          incomeStreams: [salary(pay: 200000)],
          accounts: [
            traditional401k(
              contribution: const Contribution(
                mode: ContributionMode.fixedAmount,
                value: 5000000,
                reducesFederalTaxableIncome: true,
              ),
            ),
          ],
        );
        return sumMoney(solve(h).contributions.map((c) => c.employee));
      }

      final young = contributedAt(1990);
      final fifty = contributedAt(1970);
      final sixtyOne = contributedAt(1965);
      expect(fifty > young, isTrue);
      expect(sixtyOne > fifty, isTrue,
          reason: 'the 60-to-63 tier is higher again');
    });

    test('an employer match needs pay behind it', () {
      Household withMatch({String? employerId}) => Household(
            id: 'h1',
            taxUnits: [taxUnit()],
            people: [person()],
            employers: const [
              Employer(id: 'emp-a', householdId: 'h1', label: 'Acme'),
            ],
            incomeStreams: [
              salary(pay: 100000, employerId: employerId),
            ],
            accounts: [
              traditional401k(
                employerId: employerId,
                contribution: const Contribution(
                  mode: ContributionMode.fixedAmount,
                  value: 1000000,
                  reducesFederalTaxableIncome: true,
                  employerMatch: EmployerMatch(
                    formula: MatchFormula.percentOfContribution,
                    matchRate: 0.5,
                    matchLimitPercentOfSalary: 0.06,
                  ),
                ),
              ),
            ],
          );

      final matched = solve(withMatch(employerId: 'emp-a'));
      expect(matched.contributions.first.employerMatch,
          Money.dollars(6000) * 0.5,
          reason: 'half of the first 6% of 100,000');

      final unmatched = solve(withMatch());
      expect(unmatched.contributions.first.employerMatch, Money.zero,
          reason: 'no employer, so no compensation to match against');
    });
  });

  group('§4.4.3 the fixed point', () {
    test('a year with nothing proposed settles in one pass', () {
      final r = solve(Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 150000)],
      ));
      expect(r.passes, 1);
      expect(r.waterfallNotConverged, isFalse);
    });

    test('a proposed pre-tax addition lowers the tax that priced it', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 150000)],
        accounts: [
          Account(
            id: 'ira',
            personId: 'p1',
            label: 'IRA',
            kind: AccountKind.traditionalIra,
            taxTreatment: TaxTreatment.taxDeferred,
            limitFamily: LimitFamily.ira,
            balance: Money.dollars(20000),
            isRestrictedPurpose: false,
            contribution: const Contribution(
              mode: ContributionMode.fixedAmount,
              value: 0,
              reducesFederalTaxableIncome: true,
            ),
          ),
        ],
      );
      final without = solve(h);
      final with_ = solve(h, proposed: {'ira': Money.dollars(7500)});

      expect(with_.contributions.first.employee, Money.dollars(7500));
      expect(with_.totalTaxOwed < without.totalTaxOwed, isTrue,
          reason: 'the deduction is priced into the same year');
      expect(with_.waterfallNotConverged, isFalse);
    });

    test('a proposal the limits cut back still converges', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 150000)],
        accounts: [
          Account(
            id: 'ira',
            personId: 'p1',
            label: 'IRA',
            kind: AccountKind.traditionalIra,
            taxTreatment: TaxTreatment.taxDeferred,
            limitFamily: LimitFamily.ira,
            balance: Money.dollars(20000),
            isRestrictedPurpose: false,
            contribution: const Contribution(
              mode: ContributionMode.fixedAmount,
              value: 0,
              reducesFederalTaxableIncome: true,
            ),
          ),
        ],
      );
      // Far more than the IRA limit allows: pass 1 caps it, pass 2 sees the
      // capped figure standing and stops.
      final r = solve(h, proposed: {'ira': Money.dollars(50000)});
      expect(r.contributions.first.employee,
          taxYear.contributionLimits[LimitFamily.ira]!.annual!);
      expect(r.passes, lessThanOrEqualTo(3));
      expect(r.waterfallNotConverged, isFalse);
    });
  });

  group('§4.5 the cash buffer', () {
    test('the target is months of the whole cost of living', () {
      expect(cashBufferTarget(6, Money.dollars(96000)), Money.dollars(48000));
    });
  });
}
