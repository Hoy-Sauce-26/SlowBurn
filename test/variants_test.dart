import 'package:burn_engine/burn_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slow_burn/services/flag_placement.dart';
import 'package:slow_burn/services/variants.dart';

const assumptions = Assumptions(taxYearId: 'us-2026');

Scenario scenario() => const Scenario(
      id: 'sc1',
      householdId: 'h1',
      label: 'Baseline',
      assumptions: assumptions,
    );

Household saver({int? plannedRetirementAge}) => Household(
      id: 'h1',
      taxUnits: [
        TaxUnit(
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
          plannedRetirementAge: plannedRetirementAge,
        ),
      ],
      incomeStreams: [
        IncomeStream(
          id: 'inc1',
          personId: 'p1',
          label: 'Salary',
          kind: IncomeKind.w2Wages,
          grossAnnualAmount: Money.dollars(150000),
          isFicaSubject: true,
          isQualifiedBusinessIncome: false,
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
          balance: Money.dollars(400000),
          isRestrictedPurpose: false,
          contribution: const Contribution(
            mode: ContributionMode.percentOfGross,
            value: 0.12,
            contributionBaseStreamIds: ['inc1'],
            reducesFederalTaxableIncome: true,
          ),
        ),
      ],
    );

VariantOutcome apply(
  FireVariant v, {
  Household? household,
  Money pay = const Money(3000000),
  Money premium = Money.zero,
}) =>
    applyVariant(
      v,
      household: household ?? saver(),
      scenario: scenario(),
      currentYear: 2026,
      baristaPay: pay,
      baristaPremium: premium,
    );

void main() {
  group('§9.4 traditional retirement', () {
    test('sets a planned age, which takes the person out of the solve', () {
      final out = apply(FireVariant.traditional);
      expect(out.household.people.single.plannedRetirementAge, 67);
      expect(out.changes, isNotEmpty);
    });
  });

  group('§9.3 Coast FIRE writes both halves', () {
    test('it stops the committed contributions', () {
      final out = apply(FireVariant.coast);
      expect(out.household.accounts.single.contribution.endYear, 2026);
    });

    test('and omits the saving steps from the waterfall', () {
      // Either half alone does nothing: stopping the contribution hands the
      // same money to the waterfall, which pours it back into the same
      // accounts.
      final steps = apply(FireVariant.coast).scenario.assumptions
          .contributionWaterfall;
      expect(steps, isNot(contains(WaterfallStep.electiveDeferralToLimit)));
      expect(steps, isNot(contains(WaterfallStep.iraToLimit)));
      expect(steps, isNot(contains(WaterfallStep.matchCapture)));
      expect(steps, contains(WaterfallStep.taxableBrokerage),
          reason: 'invariant 29: the surplus still needs somewhere to land');
    });

    test('the resulting scenario is valid', () {
      final out = apply(FireVariant.coast);
      expect(validateAssumptions(out.scenario.assumptions), isEmpty);
      expect(validateHousehold(out.household), isEmpty);
    });
  });

  group('§9.2 Barista FIRE', () {
    test('needs a retirement year, since that is when the job starts', () {
      final out = apply(FireVariant.barista);
      expect(out.blocked, isNotNull);
      expect(out.household.incomeStreams, hasLength(1),
          reason: 'nothing is changed while it is blocked');
    });

    test('adds part-time income with an explicit end year', () {
      // The earned kinds otherwise default to ending the year before
      // retirement, which is where this one starts.
      final out = apply(FireVariant.barista,
          household: saver(plannedRetirementAge: 55));
      final job = out.household.incomeStreams.last;
      expect(job.startYear, 1985 + 55);
      expect(job.endYear, isNotNull);
      expect(job.endYear! > job.startYear!, isTrue);
    });

    test('a job carrying cover extends coverage and adds the premium', () {
      final out = apply(
        FireVariant.barista,
        household: saver(plannedRetirementAge: 55),
        premium: Money.dollars(4800),
      );
      expect(out.household.people.single.employerHealthCoverageEndYear,
          isNotNull);
      expect(out.household.payrollDeductions, hasLength(1));
      expect(out.household.payrollDeductions.single.kind,
          PayrollDeductionKind.healthPremium);
    });

    test('a job without cover buys on the marketplace instead', () {
      final out = apply(FireVariant.barista,
          household: saver(plannedRetirementAge: 55));
      expect(out.household.payrollDeductions, isEmpty);
      expect(out.changes.join(' '), contains('marketplace'));
    });

    test('the resulting household is valid', () {
      final out = apply(FireVariant.barista,
          household: saver(plannedRetirementAge: 55),
          premium: Money.dollars(4800));
      expect(validateHousehold(out.household), isEmpty);
    });
  });

  group('§9.1 Lean and Fat are not a preset', () {
    test('they are edits to the spending lines, and it says so', () {
      final out = apply(FireVariant.leanOrFat);
      expect(out.blocked, isNotNull);
      expect(out.blocked, contains('nobody lives'),
          reason: 'a single multiplier would model a lifestyle nobody lives');
    });
  });

  group('a preset is never stored', () {
    test('the household afterwards is ordinary', () {
      // §9: no variant-specific entities. Nothing about the result says which
      // preset produced it, which is what stops a second copy of the same fact
      // from disagreeing with the first.
      final out = apply(FireVariant.coast);
      final reExported = importFromJson(exportToJson(ExportBundle(
        household: out.household,
        scenarios: [out.scenario],
        assetClasses: const [],
      )));
      expect(exportToJson(reExported), isNot(contains('variant')));
      expect(exportToJson(reExported), isNot(contains('fireType')));
    });
  });

  group('flags land on the screen that can act on them', () {
    test('every flag the engine raises has a home', () {
      const raised = {
        'shortfall', 'bufferDepleted', 'contributionLimitExceeded',
        'waterfallNotConverged', 'bridgeGapDetected', 'magiCeilingBreached',
        'acaMagiBelowSubsidyFloor', 'retirementSpendingNotLevel',
        'rothRolloverAssumed', 'earningsTestNotModeled', 'qbiLimitNotModeled',
        'unvestedMatchAtRisk', 'rothIraIncomeLimitReached',
        'hsaContributionsStoppedAtMedicare', 'escrowDiffersFromInferred',
        'payoffLeavesResidualEscrow', 'derivedPayoffDiffersFromTerm',
        'possibleDoubleCount', 'filingStatusNoLongerQualifies',
        'swrHorizonMismatch', 'electionExceededRealizedSurplus',
      };
      final homeless = raised.where((f) => !flagHomes.containsKey(f)).toList();
      expect(homeless, isEmpty,
          reason: 'a flag with no home is only ever seen in the panel');
      expect(raised, hasLength(21));
    });

    test('a mortgage flag goes to the debts screen, not the plan', () {
      // Actionable next to the mortgage, merely worrying next to the FIRE
      // number.
      expect(flagsFor(FlagHome.debts, {'escrowDiffersFromInferred', 'shortfall'}),
          {'escrowDiffersFromInferred'});
      expect(flagsFor(FlagHome.plan, {'escrowDiffersFromInferred', 'shortfall'}),
          {'shortfall'});
    });
  });
}
