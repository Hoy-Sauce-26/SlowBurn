import 'dart:io';

import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

final taxYear =
    parseTaxYear(File('../../assets/tax_years/2026.json').readAsStringSync());
const year = 2026;

TaxableIncome incomeFor(
  Household h, {
  Assumptions? assumptions,
  YearInputs inputs = const YearInputs(),
  int at = year,
}) {
  final a = assumptions ?? const Assumptions(taxYearId: 'us-2026');
  final wages = h.people
      .map((p) => computeWages(p,
          household: h, taxYear: taxYear, year: at, currentYear: year))
      .toList();
  return computeTaxableIncome(
    h.taxUnits.first,
    household: h,
    assumptions: a,
    taxYear: taxYear,
    assetClasses: assetClasses(),
    wages: wages,
    year: at,
    currentYear: year,
    inputs: inputs,
  );
}

void main() {
  group('§4.3.1 in-account investment income', () {
    test('only taxable accounts throw it off', () {
      // Distributions inside the other wrappers are not taxed in the year
      // received, which is the entire point of them.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [traditional401k(balance: 500000), brokerageIn()],
      );
      final t = incomeFor(h);
      expect(t.inAccountInvestmentIncome, Money.dollars(100000) * 0.013,
          reason: 'the 401(k) contributes nothing');
    });

    test('the qualified fraction is weighted by yield, not by balance', () {
      // A class throwing off no income contributes no dividends to qualify.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [
          Account(
            id: 'a1',
            personId: 'p1',
            label: 'Blend',
            kind: AccountKind.taxableBrokerage,
            taxTreatment: TaxTreatment.taxable,
            limitFamily: LimitFamily.none,
            balance: Money.dollars(100000),
            costBasis: Money.dollars(100000),
            isRestrictedPurpose: false,
            allocationMode: AllocationMode.weighted,
            allocationWeights: const [
              AllocationWeight(assetClassId: 'stocks', weight: 0.5),
              AllocationWeight(assetClassId: 'cash', weight: 0.5),
            ],
            contribution:
                const Contribution(mode: ContributionMode.fixedAmount, value: 0),
          ),
        ],
      );
      final t = incomeFor(h);
      // Yield is (0.5 × 1.3%) + (0.5 × 1.0%); only the stock half qualifies.
      final expected = 0.5 * 0.013 / (0.5 * 0.013 + 0.5 * 0.010);
      expect(t.qualifiedDividends.ratioTo(t.inAccountInvestmentIncome),
          closeTo(expected, 1e-6));
    });

    test('unrealised gains are realised at the scenario rate', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [brokerageIn(balance: 100000, basis: 60000)],
      );
      final t = incomeFor(h);
      // 5% of the $40,000 of unrealised gain, plus the qualified dividends
      // which are not part of realizedLongTermGains.
      expect(t.realizedLongTermGains, Money.dollars(40000) * 0.05);
    });
  });

  group('§4.3.1 Social Security taxability', () {
    Household claiming({required num benefitMonthly, num otherIncome = 0}) =>
        Household(
          id: 'h1',
          taxUnits: [taxUnit()],
          people: [
            person(
              birthYear: 1958,
              socialSecurity: SocialSecurityBenefit(
                personId: 'p1',
                estimatedMonthlyBenefitAtFra: Money.dollars(benefitMonthly),
                claimingAge: 67,
              ),
            ),
          ],
          incomeStreams: [
            if (otherIncome > 0)
              salary(pay: otherIncome, endYear: year),
          ],
        );

    test('a low-income household pays nothing on the benefit', () {
      final t = incomeFor(claiming(benefitMonthly: 1500));
      expect(t.ssBenefits.isPositive, isTrue);
      expect(t.taxableSS, Money.zero,
          reason: 'provisional income sits below the lower threshold');
    });

    test('a high-income household is capped at 85% of the benefit', () {
      final t = incomeFor(claiming(benefitMonthly: 3000, otherIncome: 200000));
      expect(t.taxableSS, t.ssBenefits * 0.85);
    });

    test('the scenario switch turns the benefit off entirely', () {
      final t = incomeFor(
        claiming(benefitMonthly: 3000),
        assumptions: const Assumptions(
          taxYearId: 'us-2026',
          includeSocialSecurity: false,
        ),
      );
      expect(t.ssBenefits, Money.zero);
      expect(t.taxableSS, Money.zero);
    });

    test('a benefit not yet claimed is not counted', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [
          person(
            birthYear: 1985,
            socialSecurity: SocialSecurityBenefit(
              personId: 'p1',
              estimatedMonthlyBenefitAtFra: Money.dollars(3000),
              claimingAge: 67,
            ),
          ),
        ],
      );
      expect(incomeFor(h).ssBenefits, Money.zero);
    });
  });

  group('§4.3.2 deduction and taxable income', () {
    test('the standard deduction applies, and the larger figure wins', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 100000)],
      );
      expect(incomeFor(h).deduction,
          taxYear.standardDeduction[FilingStatus.single]!.value);

      final itemizing = Household(
        id: 'h1',
        taxUnits: [
          TaxUnit(
            id: 'tu1',
            householdId: 'h1',
            filingStatus: FilingStatus.single,
            stateCode: 'CO',
            itemizedDeductionTotal: Money.dollars(30000),
          ),
        ],
        people: [person()],
        incomeStreams: [salary(pay: 100000)],
      );
      expect(incomeFor(itemizing).deduction, Money.dollars(30000));
    });

    test('the age-65 addition is per qualifying person', () {
      final couple = Household(
        id: 'h1',
        taxUnits: [taxUnit(filingStatus: FilingStatus.marriedFilingJointly)],
        people: [
          person(birthYear: 1955),
          person(id: 'p2', name: 'Sam', birthYear: 1956),
        ],
      );
      final one = Household(
        id: 'h1',
        taxUnits: [taxUnit(filingStatus: FilingStatus.marriedFilingJointly)],
        people: [
          person(birthYear: 1955),
          person(id: 'p2', name: 'Sam', birthYear: 1985),
        ],
      );
      final extra = taxYear
          .additionalStandardDeductionAge65[FilingStatus.marriedFilingJointly]!
          .value;
      expect(incomeFor(couple).deduction - incomeFor(one).deduction, extra);
    });
  });

  group('§4.3.2 the deduction for people over 65', () {
    Household retired({required int birthYear, required int pay,
        FilingStatus status = FilingStatus.single, Person? spouse}) => Household(
          id: 'h1',
          taxUnits: [taxUnit(filingStatus: status)],
          people: [person(birthYear: birthYear), ?spouse],
          incomeStreams: [salary(pay: pay)],
        );

    test('is worth \$6,000 a head to someone modest', () {
      final young = incomeFor(retired(birthYear: 1985, pay: 40000));
      final old = incomeFor(retired(birthYear: 1950, pay: 40000));
      expect(old.seniorDeduction, Money.dollars(6000));
      expect(young.seniorDeduction, Money.zero);
      expect(old.fedTaxable < young.fedTaxable, isTrue,
          reason: 'the deduction has to reach taxable income to be worth '
              'anything');
    });

    test('goes away as income rises, and is gone at \$175,000', () {
      expect(incomeFor(retired(birthYear: 1950, pay: 125000)).seniorDeduction,
          Money.dollars(3000),
          reason: '6% of the \$50,000 above the threshold takes half of it');
      expect(incomeFor(retired(birthYear: 1950, pay: 200000)).seniorDeduction,
          Money.zero);
    });

    test('a couple loses it at the same income a single filer does', () {
      // The statute reduces the per-person amount, so two qualifying spouses
      // get twice as much and lose it just as fast.
      final couple = retired(
        birthYear: 1950,
        pay: 200000,
        status: FilingStatus.marriedFilingJointly,
        spouse: person(id: 'p2', name: 'Sam', birthYear: 1952),
      );
      expect(incomeFor(couple).seniorDeduction, Money.dollars(6000),
          reason: '\$12,000 less 6% of the \$50,000 over \$150,000');
    });

    test('lapses after 2028, which a long projection has to see', () {
      expect(
          incomeFor(retired(birthYear: 1950, pay: 40000), at: 2028)
              .seniorDeduction
              .isPositive,
          isTrue);
      expect(incomeFor(retired(birthYear: 1950, pay: 40000), at: 2029)
          .seniorDeduction, Money.zero);
    });
  });

  group('§4.3.2 the §199A deduction', () {
    test('a wage earner gets none', () {
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [salary(pay: 150000)],
      );
      expect(incomeFor(h).qbiDeduction, Money.zero);
    });

    test('self-employment income earns 20% of QBI', () {
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
            grossAnnualAmount: Money.dollars(100000),
            isFicaSubject: false,
            isQualifiedBusinessIncome: true,
          ),
        ],
      );
      final t = incomeFor(h);
      expect(t.qbi.isPositive, isTrue);
      // Two ceilings, and the deduction is the lower. Here the standard
      // deduction has already taken $15,750 off, so taxable income binds
      // before 20% of QBI does.
      final onQbi = t.qbi * taxYear.qbiDeductionRate;
      final onTaxableIncome =
          (t.taxableBeforeQbi - t.netCapitalGain).orZeroIfNegative *
              taxYear.qbiDeductionRate;
      expect(t.qbiDeduction, minMoney(onQbi, onTaxableIncome));
      expect(t.qbiDeduction, onTaxableIncome);
      expect(t.fedTaxable, t.taxableBeforeQbi - t.qbiDeduction);
    });

    test('20% of QBI binds where other income covers the deduction', () {
      // Wages absorb the standard deduction, so taxable income is comfortably
      // above the business income and the QBI term is the lower ceiling.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        incomeStreams: [
          salary(pay: 120000),
          IncomeStream(
            id: 'se1',
            personId: 'p1',
            label: 'Consulting',
            kind: IncomeKind.selfEmployment,
            grossAnnualAmount: Money.dollars(20000),
            isFicaSubject: false,
            isQualifiedBusinessIncome: true,
          ),
        ],
      );
      final t = incomeFor(h);
      expect(t.qbiDeduction, t.qbi * taxYear.qbiDeductionRate);
    });

    test('the deduction is bounded by taxable income net of capital gain', () {
      // A household whose income is nearly all long-term gain cannot deduct
      // 20% of its business income against it.
      final h = Household(
        id: 'h1',
        taxUnits: [taxUnit()],
        people: [person()],
        accounts: [brokerageIn(balance: 2000000, basis: 200000)],
        incomeStreams: [
          IncomeStream(
            id: 'se1',
            personId: 'p1',
            label: 'Consulting',
            kind: IncomeKind.selfEmployment,
            grossAnnualAmount: Money.dollars(30000),
            isFicaSubject: false,
            isQualifiedBusinessIncome: true,
          ),
        ],
      );
      final t = incomeFor(h);
      final ceiling = (t.taxableBeforeQbi - t.netCapitalGain).orZeroIfNegative *
          taxYear.qbiDeductionRate;
      expect(t.qbiDeduction, ceiling);
      expect(t.qbiDeduction < t.qbi * taxYear.qbiDeductionRate, isTrue);
    });
  });

  group('§4.3.1 traditional IRA deductibility', () {
    Household withIra({required num income, bool alsoHas401k = false}) =>
        Household(
          id: 'h1',
          taxUnits: [taxUnit()],
          people: [person()],
          incomeStreams: [salary(pay: income)],
          accounts: [
            Account(
              id: 'ira',
              personId: 'p1',
              label: 'IRA',
              kind: AccountKind.traditionalIra,
              taxTreatment: TaxTreatment.taxDeferred,
              limitFamily: LimitFamily.ira,
              balance: Money.dollars(50000),
              isRestrictedPurpose: false,
              contribution: const Contribution(
                mode: ContributionMode.fixedAmount,
                value: 700000,
                reducesFederalTaxableIncome: true,
              ),
            ),
            if (alsoHas401k)
              traditional401k(
                contribution: const Contribution(
                  mode: ContributionMode.fixedAmount,
                  value: 1000000,
                  reducesFederalTaxableIncome: true,
                ),
              ),
          ],
        );

    test('with no workplace plan the deduction is whole', () {
      expect(incomeFor(withIra(income: 250000)).deductibleIraPortion, 1.0);
    });

    test('a workplace plan and high income phases it out entirely', () {
      final t = incomeFor(withIra(income: 250000, alsoHas401k: true));
      expect(t.deductibleIraPortion, 0.0);
    });

    test('a workplace plan and low income leaves it whole', () {
      final t = incomeFor(withIra(income: 60000, alsoHas401k: true));
      expect(t.deductibleIraPortion, 1.0);
    });

    test('the phase-out reads preDeductionMagi, which excludes the IRA itself',
        () {
      // Acyclic by construction: a deduction whose size depended on income net
      // of itself would need its own solve.
      final t = incomeFor(withIra(income: 90000, alsoHas401k: true));
      expect(t.preDeductionMagi > t.nonSSIncome, isTrue);
    });
  });
}
