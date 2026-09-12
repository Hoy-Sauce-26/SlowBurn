import 'dart:convert';
import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

final taxYear =
    parseTaxYear(File('../../assets/tax_years/2026.json').readAsStringSync());
const year = 2026;

/// The bundled ruleset with one state rewritten, for the rules no bundled
/// state exercises yet.
TaxYear taxYearWithState(String code, Map<String, dynamic> rules) {
  final j = jsonDecode(File('../../assets/tax_years/2026.json')
      .readAsStringSync()) as Map<String, dynamic>;
  (j['stateRules'] as Map<String, dynamic>)[code] = rules;
  return taxYearFromJson(j);
}

({TaxableIncome income, TaxOwed owed}) run(
  Household h, {
  Assumptions? assumptions,
  YearInputs inputs = const YearInputs(),
  WithdrawalPenalties penalties = const WithdrawalPenalties(),
  TaxYear? using,
}) {
  final a = assumptions ?? const Assumptions(taxYearId: 'us-2026');
  final ty = using ?? taxYear;
  final wages = h.people
      .map((p) => computeWages(p,
          household: h, taxYear: ty, year: year, currentYear: year))
      .toList();
  final unit = h.taxUnits.first;
  final income = computeTaxableIncome(unit,
      household: h,
      assumptions: a,
      taxYear: ty,
      assetClasses: assetClasses(),
      wages: wages,
      year: year,
      currentYear: year,
      inputs: inputs);
  final owed = computeTaxOwed(unit,
      household: h,
      income: income,
      wages: wages,
      assumptions: a,
      taxYear: ty,
      year: year,
      currentYear: year,
      inputs: inputs,
      penalties: penalties);
  return (income: income, owed: owed);
}

Dependent child({int birthYear = 2018}) =>
    Dependent(id: 'd$birthYear', birthDate: DateTime(birthYear, 4, 1));

void main() {
  group('§4.3.6 what a state gives back for a 529', () {
    Account college(String id, {String? child}) => Account(
          id: id,
          personId: 'p1',
          label: 'College',
          kind: AccountKind.education529,
          taxTreatment: TaxTreatment.educationTaxFree,
          limitFamily: LimitFamily.education,
          balance: Money.zero,
          isRestrictedPurpose: true,
          beneficiaryId: child,
          contribution: const Contribution(
              mode: ContributionMode.fixedAmount, value: 0),
        );

    Money stateTax(String state, List<Account> accounts,
            Map<Id, Money> put, {num pay = 120000}) =>
        run(
          Household(
            id: 'h1',
            taxUnits: [taxUnit(state: state)],
            people: [person()],
            incomeStreams: [salary(pay: pay)],
            accounts: accounts,
          ),
          inputs: YearInputs(resolvedContributions: put),
        ).owed.stateTax;

    test('a deduction comes off income, up to the cap', () {
      final none = stateTax('NY', [college('a')], {});
      final five =
          stateTax('NY', [college('a')], {'a': Money.dollars(5000)});
      final eight =
          stateTax('NY', [college('a')], {'a': Money.dollars(8000)});
      expect(five < none, isTrue);
      expect(eight, five,
          reason: 'New York counts \$5,000 for a single filer');
    });

    test('where it is per beneficiary, each child has a cap of their own', () {
      final put = {'a': Money.dollars(4000), 'b': Money.dollars(4000)};
      final twoChildren = stateTax('GA',
          [college('a', child: 'k1'), college('b', child: 'k2')], put);
      final oneChild = stateTax('GA',
          [college('a', child: 'k1'), college('b', child: 'k1')], put);
      expect(twoChildren < oneChild, isTrue);
    });

    test('a credit comes off the tax itself', () {
      final none = stateTax('IN', [college('a')], {});
      final most =
          stateTax('IN', [college('a')], {'a': Money.dollars(10000)});
      expect(none - most, Money.dollars(1500),
          reason: '20% of the first \$7,500');
    });

    test('nothing above the income limit', () {
      final none = stateTax('NJ', [college('a')], {}, pay: 300000);
      final put = stateTax(
          'NJ', [college('a')], {'a': Money.dollars(10000)}, pay: 300000);
      expect(put, none);
    });

    test('and nothing in a state that offers none', () {
      final none = stateTax('CA', [college('a')], {});
      final put =
          stateTax('CA', [college('a')], {'a': Money.dollars(10000)});
      expect(put, none);
    });
  });

  group('§4.3.3 the two schedules', () {
    test('the portions always sum to taxable income', () {
      final r = run(Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 120000)],
        accounts: [brokerageIn(balance: 500000, basis: 200000)],
      ));
      expect(r.owed.ordinaryPortion + r.owed.preferentialPortion,
          r.income.fedTaxable);
    });

    test('NIIT reaches only investment income, and only above the threshold',
        () {
      final low = run(Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 80000)],
        accounts: [brokerageIn(balance: 400000, basis: 200000)],
      ));
      expect(low.owed.niit, Money.zero, reason: 'AGI below the threshold');

      final high = run(Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 300000)],
        accounts: [brokerageIn(balance: 400000, basis: 200000)],
      ));
      expect(high.owed.niit.isPositive, isTrue);
      expect(high.owed.niit <= high.owed.netInvestmentIncome * taxYear.niitRate,
          isTrue,
          reason: 'capped by investment income, not by the AGI excess alone');
    });

    test('wages alone never pay NIIT however high', () {
      final r = run(Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 900000)],
      ));
      expect(r.owed.netInvestmentIncome, Money.zero);
      expect(r.owed.niit, Money.zero);
    });

    test('recapture is taxed at its own flat rate, outside the schedules', () {
      final r = run(
        Household(
          id: 'h1',
          taxUnits: [taxUnit()],
          people: [person()],
          incomeStreams: [salary(pay: 100000)],
        ),
        inputs: YearInputs(assetSaleRecapture: Money.dollars(50000)),
      );
      expect(r.owed.recaptureTax,
          Money.dollars(50000) * taxYear.unrecapturedSection1250Rate);
    });
  });

  group('§4.3.4 the Child Tax Credit', () {
    Household withChildren(int n, {num pay = 90000}) => Household(
          id: 'h1',
          taxUnits: [
            taxUnit(dependents: [for (var i = 0; i < n; i++) child()])
          ],
          people: [person()],
          incomeStreams: [salary(pay: pay)],
        );

    test('a household with no children gets nothing', () {
      expect(run(withChildren(0)).owed.childTaxCredit, Money.zero);
    });

    test('the credit scales with qualifying children', () {
      final one = run(withChildren(1)).owed.childTaxCredit;
      final two = run(withChildren(2)).owed.childTaxCredit;
      expect(two, one * 2);
    });

    test('a child past the qualifying age no longer counts', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit(dependents: [child(birthYear: 2008)])],
        people: [person()],
        incomeStreams: [salary(pay: 90000)],
      );
      expect(run(h).owed.childTaxCredit, Money.zero,
          reason: '2026 minus 2008 is 18, past the qualifying age');
    });

    test('it phases out per step above the threshold', () {
      final rich = run(withChildren(2, pay: 600000));
      expect(rich.owed.childTaxCredit, Money.zero);
    });

    test('the refundable portion is bounded, so tax goes only so negative', () {
      // Low earned income: the non-refundable half has no tax to offset and
      // the refundable half is capped by a fraction of earnings above a floor.
      final r = run(withChildren(3, pay: 16000));
      expect(r.owed.federalTax.isNegative, isTrue);
      final cap = taxYear.childTaxCreditRefundablePerChild * 3;
      expect(r.owed.childTaxCredit <= cap, isTrue);
    });
  });

  group('§4.3.5 the ACA premium tax credit', () {
    Household retiree({num draw = 60000, int? coverageEnd}) => Household(
          id: 'h1',
          taxUnits: [taxUnit()],
          people: [
            Person(
              id: 'p1',
              displayName: 'Alex',
              birthDate: DateTime(1975, 6, 15),
              taxUnitId: 'tu1',
              employerHealthCoverageEndYear: coverageEnd,
            ),
          ],
          incomeStreams: [salary(pay: draw)],
        );

    test('an early retiree buying their own cover gets a credit', () {
      final r = run(retiree(draw: 45000, coverageEnd: 2020));
      expect(r.owed.health.benchmarkPremium.isPositive, isTrue);
      expect(r.owed.health.eligible, isTrue);
      expect(r.owed.health.premiumTaxCredit.isPositive, isTrue);
      expect(r.owed.health.netPremium < r.owed.health.benchmarkPremium, isTrue);
    });

    test('employer coverage suppresses both the premium and the credit', () {
      final r = run(retiree(draw: 45000, coverageEnd: 2040));
      expect(r.owed.health.benchmarkPremium, Money.zero);
      expect(r.owed.health.premiumTaxCredit, Money.zero);
    });

    test('an empty covered set zeroes the premium before an override is read',
        () {
      // The fallback sums over nobody; an entered override does not, so the
      // gate has to come first or the household pays a premium it does not owe.
      final h = Household(
        id: 'h1',
        taxUnits: [
          TaxUnit(
            id: 'tu1',
            householdId: 'h1',
            filingStatus: FilingStatus.single,
            stateCode: 'CO',
            benchmarkPremiumOverride: Money.dollars(9000),
          ),
        ],
        people: [person(birthYear: 1950)],
        incomeStreams: [salary(pay: 45000)],
      );
      expect(run(h).owed.health.benchmarkPremium, Money.zero,
          reason: 'the only person is past 65');
    });

    test('below the subsidy floor there is no credit, and it is flagged', () {
      final r = run(retiree(draw: 8000, coverageEnd: 2020));
      expect(r.owed.health.premiumTaxCredit, Money.zero);
      expect(r.owed.health.belowSubsidyFloor, isTrue);
    });

    test('a higher income buys less subsidy', () {
      final poor = run(retiree(draw: 35000, coverageEnd: 2020));
      final rich = run(retiree(draw: 70000, coverageEnd: 2020));
      expect(rich.owed.health.premiumTaxCredit <
          poor.owed.health.premiumTaxCredit, isTrue);
    });

    test('a dollar over four times the poverty line costs the whole credit',
        () {
      // The enhanced credits lapsed after 2025, so 2026 brings back the cliff.
      // A bridge plan that lands just over it loses every dollar of subsidy,
      // which is the single most expensive mistake this app can help avoid.
      final under = run(retiree(draw: 62000, coverageEnd: 2020));
      final over = run(retiree(draw: 66000, coverageEnd: 2020));

      expect(under.owed.health.fplPercent, lessThan(400));
      expect(over.owed.health.fplPercent, greaterThan(400));
      expect(under.owed.health.premiumTaxCredit.isPositive, isTrue);
      expect(over.owed.health.eligible, isFalse);
      expect(over.owed.health.premiumTaxCredit, Money.zero);
    });

    test('acaMagi adds back the untaxed half of a benefit', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [
          Person(
            id: 'p1',
            displayName: 'Alex',
            birthDate: DateTime(1962, 6, 15),
            taxUnitId: 'tu1',
            employerHealthCoverageEndYear: 2020,
            socialSecurity: SocialSecurityBenefit(
              personId: 'p1',
              estimatedMonthlyBenefitAtFra: Money.dollars(2000),
              claimingAge: 63,
            ),
          ),
        ],
      );
      final r = run(h);
      expect(r.owed.health.acaMagi > r.income.federalAgi, isTrue);
      expect(r.owed.health.acaMagi - r.income.federalAgi,
          r.income.ssBenefits - r.income.taxableSS);
    });
  });

  group('§4.3.6 state, local, and the total', () {
    test('a no-tax state charges nothing', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit(state: 'TX')],
        people: [person()],
        incomeStreams: [salary(pay: 150000)],
      );
      expect(run(h).owed.stateTax, Money.zero);
    });

    test('a flat state charges its rate on AGI less its deduction', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit(state: 'CO')],
        people: [person()],
        incomeStreams: [salary(pay: 150000)],
      );
      final r = run(h);
      final co = taxYear.stateRules['CO']!;
      expect(r.owed.stateTax,
          (r.income.federalAgi - co.standardDeductionFor(FilingStatus.single)) *
              co.flatRate!);
    });

    test('a couple is taxed on the couple\'s schedule', () {
      // California's brackets are twice as wide for a joint return, so the
      // same income owes less. Reading a single filer's schedule for a married
      // household was the error the per-status split exists to prevent.
      Money owed(FilingStatus status) => run(Household(
            id: 'h1',
            taxUnits: [taxUnit(state: 'CA', filingStatus: status)],
            people: [person()],
            incomeStreams: [salary(pay: 150000)],
          )).owed.stateTax;

      expect(owed(FilingStatus.marriedFilingJointly).cents,
          lessThan(owed(FilingStatus.single).cents));
    });

    test('a personal credit comes off the tax, not off income', () {
      // Six states hand out a flat credit where others give an exemption.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit(state: 'CA')],
        people: [person()],
        incomeStreams: [salary(pay: 150000)],
      );
      final withCredit = run(h).owed.stateTax;
      final without = run(h,
              using: taxYearWithState('CA', {
                'brackets': {
                  'single': [
                    {'upTo': null, 'rate': 0.093}
                  ]
                },
                'standardDeduction': 554000,
              }))
          .owed.stateTax;
      expect(withCredit.isPositive, isTrue);
      expect(without - withCredit, isNot(Money.zero));
    });

    test('a credit cannot push a state refund', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit(state: 'ZZ')],
        people: [person()],
        incomeStreams: [salary(pay: 20000)],
      );
      final owed = run(h,
          using: taxYearWithState('ZZ', {
            'flatRate': 0.01,
            'personalCredit': 500000,
          })).owed.stateTax;
      expect(owed, Money.zero,
          reason: 'a \$5,000 credit against \$140 of tax stops at zero');
    });

    test('a retirement exclusion shelters retirement income and no more', () {
      // Illinois and Pennsylvania exempt retirement income almost entirely.
      // Subtracting that from a salary would exempt the salary too.
      Household earning({required int pay}) => Household(
            id: 'h1',
            taxUnits: [taxUnit(state: 'ZZ')],
            people: [person()],
            incomeStreams: [salary(pay: pay)],
          );
      final generous = taxYearWithState('ZZ', {
        'flatRate': 0.05,
        'retirementIncomeExclusion': 10000000,
      });

      final worker = run(earning(pay: 100000), using: generous);
      expect(worker.owed.stateTax.isPositive, isTrue,
          reason: 'wages are not retirement income');

      final retiree = run(earning(pay: 0),
          using: generous,
          inputs: YearInputs(rmdIncome: Money.dollars(60000)));
      expect(retiree.owed.stateTax, Money.zero,
          reason: 'a hundred thousand of exclusion covers a sixty thousand '
              'dollar pension draw');
    });

    test('a non-conforming state adds pre-tax deferrals back', () {
      // Pennsylvania taxes 401(k) contributions at the state level (§4.3.3).
      Household inState(String code) => Household(
            id: 'h1',
            taxUnits: [taxUnit(state: code)],
            people: [person()],
            incomeStreams: [salary(pay: 150000)],
            accounts: [
              traditional401k(
                contribution: const Contribution(
                  mode: ContributionMode.fixedAmount,
                  value: 2000000,
                  reducesFederalTaxableIncome: true,
                  reducesStateTaxableIncome: true,
                ),
              ),
            ],
          );
      final pa = run(inState('PA'));
      final paRules = taxYear.stateRules['PA']!;
      expect(paRules.conformsToPreTaxDeferrals, isFalse);
      expect(
        pa.owed.stateTax,
        (pa.income.federalAgi + Money.dollars(20000)) * paRules.flatRate!,
        reason: 'the deferral is added back before the state schedule runs',
      );
    });

    test('the total gathers every layer, penalties included', () {
      final r = run(
        Household(
          id: 'h1',
          taxUnits: [taxUnit()],
          people: [person()],
          incomeStreams: [salary(pay: 150000)],
        ),
        penalties: WithdrawalPenalties(
          earlyRetirementDraws: Money.dollars(20000),
        ),
      );
      expect(r.owed.withdrawalPenalty,
          Money.dollars(20000) * taxYear.earlyWithdrawalPenaltyRate);
      expect(
        r.owed.totalTaxOwed,
        r.owed.federalTax +
            r.owed.stateTax +
            r.owed.localTax +
            r.owed.payrollTax +
            r.owed.additionalMedicareTax +
            r.owed.withdrawalPenalty,
      );
    });

    test('the penalty is a charge on the amount drawn, taking no deduction',
        () {
      // Leaving it out would price the bridge as free, which §8.3 and §8.4
      // exist to prevent.
      final base = run(Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 150000)],
      ));
      final penalised = run(
        Household(
          id: 'h1',
          taxUnits: [taxUnit()],
          people: [person()],
          incomeStreams: [salary(pay: 150000)],
        ),
        penalties: WithdrawalPenalties(
          hsaNonMedicalDraws: Money.dollars(10000),
        ),
      );
      expect(penalised.owed.federalTax, base.owed.federalTax,
          reason: 'it is added after credits and changes no other figure');
      expect(penalised.owed.totalTaxOwed - base.owed.totalTaxOwed,
          Money.dollars(10000) * taxYear.hsaNonMedicalPenaltyRate);
    });
  });
}
