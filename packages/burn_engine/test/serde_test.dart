import 'package:burn_engine/burn_engine.dart';
import 'package:test/test.dart';

import 'fixtures/households.dart';

/// A household exercising every entity and every optional field, so the round
/// trip has something to lose.
Household everything() => Household(
      id: 'h1',
      expenseSharing: ExpenseSharing.proportional,
      taxUnits: [
        TaxUnit(
          id: 'tu1',
          householdId: 'h1',
          filingStatus: FilingStatus.marriedFilingJointly,
          stateCode: 'PA',
          localityCode: 'PHL',
          dependents: [
            Dependent(id: 'd1', birthDate: DateTime(2016, 4, 2), isStudent: true),
            Dependent(
              id: 'd2',
                birthDate: DateTime(2010, 1, 9), supportEndYear: 2032),
          ],
          benchmarkPremiumOverride: Money.dollars(9400),
          itemizedDeductionTotal: Money.dollars(31000),
        ),
      ],
      people: [
        Person(
          id: 'p1',
          displayName: 'Alex',
          birthDate: DateTime(1982, 7, 21),
          taxUnitId: 'tu1',
          plannedRetirementAge: 58,
          hsaCoverage: const [
            HsaCoverageEntry(fromYear: 2020, tier: HsaTier.family),
            HsaCoverageEntry(fromYear: 2034, tier: HsaTier.self),
          ],
          employerHealthCoverageEndYear: 2039,
          socialSecurity: SocialSecurityBenefit(
            personId: 'p1',
            estimatedMonthlyBenefitAtFra: Money.dollars(3120.55),
            claimingAge: 67,
            includeInProjection: false,
          ),
        ),
      ],
      employers: const [
        Employer(id: 'emp', householdId: 'h1', label: 'Acme'),
      ],
      incomeStreams: [
        IncomeStream(
          id: 'inc1',
          personId: 'p1',
          employerId: 'emp',
          label: 'Salary',
          kind: IncomeKind.w2Wages,
          grossAnnualAmount: Money.dollars(184300.17),
          realGrowthRate: 0.012,
          startYear: 2026,
          endYear: 2040,
          startMonth: 3,
          endMonth: 9,
          isFicaSubject: true,
          isQualifiedBusinessIncome: false,
          isSpecifiedServiceBusiness: true,
          variability: IncomeVariability.variable,
        ),
      ],
      accounts: [
        Account(
          id: 'k1',
          personId: 'p1',
          label: '401(k)',
          kind: AccountKind.traditional401k,
          taxTreatment: TaxTreatment.taxDeferred,
          limitFamily: LimitFamily.electiveDeferral,
          balance: Money.dollars(412345.67),
          costBasis: Money.dollars(1.23),
          rothContributionBasis: Money.dollars(4.56),
          rothFirstContributionYear: 2015,
          employerId: 'emp',
          allocationMode: AllocationMode.weighted,
          allocationWeights: const [
            AllocationWeight(assetClassId: 'stocks', weight: 0.7),
            AllocationWeight(assetClassId: 'cash', weight: 0.3),
          ],
          isRestrictedPurpose: false,
          targetBalanceMonths: 6.5,
          contribution: const Contribution(
            mode: ContributionMode.percentOfGross,
            value: 0.12,
            contributionBaseStreamIds: ['inc1'],
            reducesFederalTaxableIncome: true,
            reducesStateTaxableIncome: true,
            startYear: 2026,
            endMonth: 11,
            employerMatch: EmployerMatch(
              formula: MatchFormula.tiered,
              matchRate: 0.5,
              matchLimitPercentOfSalary: 0.06,
              tiers: [
                MatchTier(upToPercentOfSalary: 0.03, matchRate: 1.0),
                MatchTier(upToPercentOfSalary: 0.06, matchRate: 0.5),
              ],
              vestingSchedule: GradedVesting([
                (years: 2, vested: 0.2),
                (years: 5, vested: 1.0),
              ]),
            ),
          ),
        ),
        Account(
          id: '529',
          personId: 'p1',
          label: 'College',
          kind: AccountKind.education529,
          taxTreatment: TaxTreatment.educationTaxFree,
          limitFamily: LimitFamily.education,
          balance: Money.dollars(51000),
          isRestrictedPurpose: true,
          contribution:
              const Contribution(mode: ContributionMode.fixedAmount, value: 0),
        ),
      ],
      payrollDeductions: [
        const PayrollDeduction(
          id: 'pd1',
          personId: 'p1',
          label: 'Family premium',
          kind: PayrollDeductionKind.healthPremium,
          annualAmount: Money(942055),
          reducesFicaWages: true,
          expenseCategoryId: 'cat-health',
          startMonth: 2,
        ),
      ],
      assets: [
        Asset(
          id: 'rental',
          householdId: 'h1',
          personId: 'p1',
          label: 'Duplex',
          category: AssetCategory.investmentProperty,
          currentValue: Money.dollars(480000),
          costBasis: Money.dollars(390000),
          realAppreciationRate: 0.008,
          accumulatedDepreciation: Money.dollars(45000),
          landFraction: 0.22,
          securedByLiabilityId: 'mtg',
          acquisitionYear: 2018,
          purchaseFundingAccountId: 'k1',
          plannedSaleYear: 2044,
          saleProceedsAccountId: 'k1',
        ),
      ],
      liabilities: [
        Liability(
          id: 'mtg',
          householdId: 'h1',
          personId: 'p1',
          label: 'Rental mortgage',
          kind: LiabilityKind.mortgage,
          currentBalance: Money.dollars(288000.44),
          interestRate: 0.0575,
          monthlyPayment: Money.dollars(2210.10),
          monthlyEscrowAmount: Money.dollars(455),
          monthlyPmiAmount: Money.dollars(88),
          escrowContinuesAfterPayoff: 0.8,
          extraPrincipalPayment: Money.dollars(150),
          originationDate: DateTime(2018, 6, 15),
          termMonths: 360,
          securedAssetId: 'rental',
          isTaxDeductibleInterest: true,
        ),
      ],
      expenseCategories: const [
        ExpenseCategory(
          id: 'cat-health',
          householdId: 'h1',
          label: 'Health',
          metaCategory: MetaCategory.health,
          defaultRelativeInflation: 0.025,
        ),
      ],
      expenseItems: const [
        ExpenseItem(
          id: 'e1',
          categoryId: 'cat-health',
          label: 'Dental',
          amount: Money(120055),
          frequency: ExpenseFrequency.quarterly,
          startYear: 2026,
          endYear: 2050,
          startMonth: 4,
          endMonth: 10,
          relativeInflationRate: 0.031,
          phase: ExpensePhase.both,
          postRetirementAmount: Money(180000),
        ),
      ],
      oneTimeEvents: [
        OneTimeEvent(
          id: 'ev1',
          householdId: 'h1',
          personId: 'p1',
          label: 'Truck',
          year: 2031,
          amount: Money.dollars(-41999.99),
          kind: OneTimeEventKind.vehiclePurchase,
          accountId: 'k1',
          taxTreatment: EventTaxTreatment.nonTaxable,
        ),
      ],
    );

ExportBundle bundle() => ExportBundle(
      household: everything(),
      scenarios: [
        Scenario(
          id: 'sc1',
          householdId: 'h1',
          label: 'Retire in Colorado at 55',
          assumptions: const Assumptions(
            taxYearId: 'us-2026',
            safeWithdrawalRate: 0.0335,
            contributionWaterfall: [
              WaterfallStep.highInterestDebt,
              WaterfallStep.taxableBrokerage,
            ],
            withdrawalOrder: [
              WithdrawalSource.cash,
              WithdrawalSource.traditional,
            ],
            includeSocialSecurity: false,
            projectionHorizonAge: 100,
          ),
        ),
      ],
      assetClasses: assetClasses().values.toList(),
    );

void main() {
  group('§11 export and import', () {
    test('a household survives the round trip exactly', () {
      final restored = importFromJson(exportToJson(bundle()));
      // Re-exporting the restored bundle must give byte-identical JSON: that is
      // what "exactly" means, and it catches a field silently dropped far more
      // reliably than asserting on any one of them.
      expect(exportToJson(restored), exportToJson(bundle()));
    });

    test('money crosses as integer cents, so nothing rounds', () {
      final restored = importFromJson(exportToJson(bundle()));
      expect(restored.household.incomeStreams.first.grossAnnualAmount,
          Money.dollars(184300.17));
      expect(restored.household.liabilities.first.currentBalance.cents,
          28800044);
    });

    test('a 529 keeps its wire name across the boundary', () {
      final json = exportToJson(bundle());
      expect(json, contains('"kind": "529"'),
          reason: 'the identifier cannot start with a digit in Dart, and the '
              'file should not carry that limitation');
      final restored = importFromJson(json);
      expect(restored.household.accounts[1].kind, AccountKind.education529);
    });

    test('the tax year never travels; asset classes do', () {
      final json = exportToJson(bundle());
      expect(json, isNot(contains('federalBrackets')),
          reason: 'bundled data ships in and nothing ships out');
      expect(importFromJson(json).assetClasses, hasLength(2),
          reason: 'the user edits these and no bundle can restore them');
    });

    test('a file from a newer build is refused rather than half-read', () {
      expect(
        () => importFromJson('{"schemaVersion": 99, "household": {}}'),
        throwsA(isA<ExportFormatException>()),
      );
    });

    test('a file that is not one of ours is refused', () {
      expect(() => importFromJson('{"steps": 4000}'),
          throwsA(isA<ExportFormatException>()));
    });

    test('fractional cents are refused rather than rounded', () {
      // Invariant 10 in the file format: a fractional cent is a mistake in the
      // file, so it is refused instead of silently rounded into the plan.
      final map = exportToMap(bundle());
      final account =
          (map['household']['accounts'] as List<dynamic>).first
              as Map<String, dynamic>;
      account['balance'] = 412345.67;
      expect(() => importFromMap(map), throwsA(isA<ExportFormatException>()));
    });

    test('a malformed file says so instead of surfacing a cast error', () {
      expect(
        () => importFromMap({
          'schemaVersion': 1,
          'household': {
            'id': 'h1',
            'expenseSharing': 'pooled',
            'accounts': [
              {'balance': 100},
            ],
          },
        }),
        throwsA(isA<ExportFormatException>()),
        reason: 'the account has no id, and the user should be told that '
            'rather than shown a type cast',
      );
    });
  });

  group('§10.1 when a snapshot is written', () {
    final assumptions = const Assumptions(taxYearId: 'us-2026');
    final classes = assetClasses().values.toList();

    String digestOf(Household h) => inputDigest(
        household: h, assumptions: assumptions, assetClasses: classes);

    ProjectionSnapshot snap({
      required DateTime at,
      required String digest,
      SnapshotTrigger trigger = SnapshotTrigger.auto,
    }) =>
        ProjectionSnapshot(
          id: 'snap-${at.toIso8601String()}-$digest',
          scenarioId: 'sc1',
          asOfDate: at,
          trigger: trigger,
          inputDigest: digest,
          taxYearId: 'us-2026',
          retirementYear: const Band(
              pessimistic: 2045, expected: 2041, optimistic: 2038),
          fireNumber: Band(
            pessimistic: Money.dollars(2600000),
            expected: Money.dollars(2350000),
            optimistic: Money.dollars(2100000),
          ),
          sustainableLevelSpending: Band(
            pessimistic: Money.dollars(70000),
            expected: Money.dollars(82000),
            optimistic: Money.dollars(95000),
          ),
          netWorth: Money.dollars(900000),
          liquidNetWorth: Money.dollars(700000),
          investableNetWorth: Money.dollars(650000),
          afterTaxLiquidNetWorth: Money.dollars(600000),
          savingsRate: 0.28,
        );

    test('the digest is stable across runs for unchanged inputs', () {
      expect(digestOf(everything()), digestOf(everything()));
    });

    test('it moves when household state moves', () {
      final edited = Household(
        id: 'h1',
        taxUnits: everything().taxUnits,
        people: everything().people,
        accounts: [
          ...everything().accounts.skip(1),
          Account(
            id: 'k1',
            personId: 'p1',
            label: '401(k)',
            kind: AccountKind.traditional401k,
            taxTreatment: TaxTreatment.taxDeferred,
            limitFamily: LimitFamily.electiveDeferral,
            balance: Money.dollars(412346),
            isRestrictedPurpose: false,
            contribution: const Contribution(
                mode: ContributionMode.fixedAmount, value: 0),
          ),
        ],
      );
      expect(digestOf(edited), isNot(digestOf(everything())));
    });

    test('it moves when the assumptions move', () {
      final a = inputDigest(
        household: everything(),
        assumptions: const Assumptions(taxYearId: 'us-2026'),
        assetClasses: classes,
      );
      final b = inputDigest(
        household: everything(),
        assumptions:
            const Assumptions(taxYearId: 'us-2026', safeWithdrawalRate: 0.035),
        assetClasses: classes,
      );
      expect(a, isNot(b));
    });

    test('it moves when the asset class rates move', () {
      final edited = [
        ...classes.skip(1),
        const AssetClass(
          id: 'stocks',
          label: AssetClassLabel.usStocks,
          expectedRealReturn: 0.04,
          pessimisticRealReturn: 0.02,
          optimisticRealReturn: 0.08,
        ),
      ];
      expect(
        inputDigest(
            household: everything(),
            assumptions: assumptions,
            assetClasses: edited),
        isNot(digestOf(everything())),
      );
    });

    test('an unchanged plan writes nothing at all', () {
      final digest = digestOf(everything());
      final decision = snapshotDecision(
        existing: [snap(at: DateTime(2026, 9, 1), digest: digest)],
        trigger: SnapshotTrigger.auto,
        digest: digest,
        asOfDate: DateTime(2026, 9, 6),
      );
      expect(decision.action, SnapshotAction.skip);
    });

    test('a second edit the same day supersedes the first', () {
      // A sitting collapses to the state the user settled on rather than to the
      // first thing they typed.
      final morning = snap(at: DateTime(2026, 9, 6, 9), digest: 'aaa');
      final decision = snapshotDecision(
        existing: [morning],
        trigger: SnapshotTrigger.auto,
        digest: 'bbb',
        asOfDate: DateTime(2026, 9, 6, 17),
      );
      expect(decision.action, SnapshotAction.writeReplacingToday);
      expect(decision.supersedes, morning);
    });

    test('an edit on a new day supersedes nothing', () {
      final decision = snapshotDecision(
        existing: [snap(at: DateTime(2026, 9, 5), digest: 'aaa')],
        trigger: SnapshotTrigger.auto,
        digest: 'bbb',
        asOfDate: DateTime(2026, 9, 6),
      );
      expect(decision.action, SnapshotAction.write);
      expect(decision.supersedes, isNull);
    });

    test('a manual checkpoint is never throttled', () {
      final digest = digestOf(everything());
      final decision = snapshotDecision(
        existing: [
          snap(at: DateTime(2026, 9, 6, 9), digest: digest),
        ],
        trigger: SnapshotTrigger.manual,
        digest: digest,
        asOfDate: DateTime(2026, 9, 6, 17),
      );
      expect(decision.action, SnapshotAction.write,
          reason: 'a deliberate save this as a checkpoint always writes');
    });

    test('a manual snapshot is never the one superseded', () {
      final pinned = snap(
          at: DateTime(2026, 9, 6, 9),
          digest: 'aaa',
          trigger: SnapshotTrigger.manual);
      final decision = snapshotDecision(
        existing: [pinned],
        trigger: SnapshotTrigger.auto,
        digest: 'bbb',
        asOfDate: DateTime(2026, 9, 6, 17),
      );
      expect(decision.action, SnapshotAction.write);
      expect(decision.supersedes, isNull);
    });
  });
}
