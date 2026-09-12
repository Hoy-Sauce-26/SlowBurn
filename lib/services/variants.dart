import 'package:burn_engine/burn_engine.dart';

import 'providers.dart';

/// §9's four shapes, as recipes over a household rather than a field on it.
///
/// §9 opens with "no variant-specific entities", and that holds here: a preset
/// writes the same entities a user would have written by hand and is never
/// stored. If a household has an `IncomeStream` running past retirement it *is*
/// Barista; a `fireType` alongside that would be a second copy of the same fact
/// with its own way of being wrong.
///
/// The presets exist because the recipes are error-prone, not because the app
/// needs to remember which one was used. Coast needs two coordinated edits and
/// half of it silently does nothing; Barista needs four.
enum FireVariant {
  traditional,
  coast,
  barista,
  leanOrFat;

  String get title => switch (this) {
        traditional => 'Traditional retirement',
        coast => 'Coast FIRE',
        barista => 'Barista FIRE',
        leanOrFat => 'Lean or Fat FIRE',
      };

  String get blurb => switch (this) {
        traditional =>
          'Stopping at the conventional age, with no early years to bridge.',
        coast =>
          'Saving only until the balance will reach the target on its own, '
              'then working on to cover current costs while it compounds '
              'untouched.',
        barista =>
          'Retiring early into part-time work, often kept for its health '
              'coverage, with savings already funding the rest.',
        leanOrFat =>
          'Early retirement on a deliberately small budget, or on a large one.',
      };

  /// What separates the two that get confused. Coast sits before the retirement
  /// year and Barista after it: a coaster still covers their whole cost of
  /// living from work, a barista's savings are already paying part of it.
  String? get contrast => switch (this) {
        coast => 'You are still working full cost of living. Nothing is drawn '
            'from savings yet.',
        barista => 'You have retired. Part-time work covers some of the cost '
            'and savings cover the rest.',
        _ => null,
      };
}

/// What applying a preset changed, so the user can see the recipe rather than
/// having it happen to them.
class VariantOutcome {
  final Household household;
  final Scenario scenario;
  final List<String> changes;

  /// Why the preset could not be applied, where it could not.
  final String? blocked;

  const VariantOutcome({
    required this.household,
    required this.scenario,
    required this.changes,
    this.blocked,
  });
}

VariantOutcome applyVariant(
  FireVariant variant, {
  required Household household,
  required Scenario scenario,
  required int currentYear,
  /// Barista only: what the part-time job pays, and whether it carries cover.
  Money baristaPay = Money.zero,
  Money baristaPremium = Money.zero,
  int baristaEndYear = 0,
  int traditionalAge = 67,
}) {
  if (household.people.isEmpty) {
    return VariantOutcome(
      household: household,
      scenario: scenario,
      changes: const [],
      blocked: 'Add a person first: every variant is a change to someone\'s '
          'plan.',
    );
  }

  return switch (variant) {
    FireVariant.traditional => _traditional(household, scenario, traditionalAge),
    FireVariant.coast => _coast(household, scenario, currentYear),
    FireVariant.barista => _barista(household, scenario,
        pay: baristaPay, premium: baristaPremium, endYear: baristaEndYear),
    FireVariant.leanOrFat => VariantOutcome(
        household: household,
        scenario: scenario,
        changes: const [],
        blocked:
            'Lean and Fat are edits to the spending lines themselves, not a '
                'preset. Set what each line becomes after retirement: a car '
                'that stops, an apartment that starts, travel at five times '
                'its working figure. A single multiplier would model a '
                'lifestyle nobody lives.',
      ),
  };
}

/// §9.4. One field, and the cheapest case the engine runs.
VariantOutcome _traditional(Household h, Scenario s, int age) => VariantOutcome(
      household: h.copyWith(
        people: [
          for (final p in h.people)
            Person(
              id: p.id,
              displayName: p.displayName,
              birthDate: p.birthDate,
              taxUnitId: p.taxUnitId,
              plannedRetirementAge: age,
              hsaCoverage: p.hsaCoverage,
              employerHealthCoverageEndYear: p.employerHealthCoverageEndYear,
              socialSecurity: p.socialSecurity,
            ),
        ],
      ),
      scenario: s,
      changes: [
        'Set everyone to retire at $age, so the engine stops solving for a date',
        'The bridge period is empty, and no withdrawal is early enough to be '
            'penalised',
      ],
    );

/// §9.3. Both halves, because either alone does nothing.
VariantOutcome _coast(Household h, Scenario s, int currentYear) {
  final stopped = <String>[];
  final accounts = [
    for (final a in h.accounts)
      if (a.contribution.value > 0 && a.contribution.endYear == null)
        () {
          stopped.add(a.label);
          return _withContributionEnd(a, currentYear);
        }()
      else
        a,
  ];

  const coasting = [
    WaterfallStep.highInterestDebt,
    WaterfallStep.cashBufferToTarget,
    WaterfallStep.taxableBrokerage,
  ];

  return VariantOutcome(
    household: h.copyWith(accounts: accounts),
    scenario: Scenario(
      id: s.id,
      householdId: s.householdId,
      label: s.label,
      assumptions: _withWaterfall(s.assumptions, coasting),
    ),
    changes: [
      if (stopped.isEmpty)
        'No committed contributions to stop'
      else
        'Stopped contributions to ${stopped.join(', ')} after $currentYear',
      'Removed the saving steps from the waterfall, leaving debt paydown, the '
          'cash buffer and the brokerage',
      'Without the second half the surplus would pour straight back into the '
          'same accounts',
    ],
  );
}

/// §9.2. The part-time job, and the coverage that usually comes with it.
VariantOutcome _barista(
  Household h,
  Scenario s, {
  required Money pay,
  required Money premium,
  required int endYear,
}) {
  final person = h.people.first;
  final retirement = person.plannedRetirementYear;
  if (retirement == null) {
    return VariantOutcome(
      household: h,
      scenario: s,
      changes: const [],
      blocked: 'Set a planned retirement age first: a Barista job starts when '
          'the career stops, and the engine needs to know when that is.',
    );
  }

  final changes = <String>[];
  final streams = [
    ...h.incomeStreams,
    IncomeStream(
      id: newId('inc'),
      personId: person.id,
      label: 'Part-time work',
      kind: IncomeKind.w2Wages,
      grossAnnualAmount: pay,
      // An explicit endYear, since the earned kinds otherwise default to
      // ending the year before retirement, which is where this one starts.
      startYear: retirement,
      endYear: endYear > retirement ? endYear : retirement + 5,
      isFicaSubject: true,
      isQualifiedBusinessIncome: false,
      variability: IncomeVariability.variable,
    ),
  ];
  changes.add('Added part-time income from $retirement, with an explicit end '
      'year so it is not stopped at retirement');

  var people = h.people;
  var deductions = h.payrollDeductions;
  if (premium.isPositive) {
    people = [
      for (final p in h.people)
        if (p.id == person.id)
          Person(
            id: p.id,
            displayName: p.displayName,
            birthDate: p.birthDate,
            taxUnitId: p.taxUnitId,
            plannedRetirementAge: p.plannedRetirementAge,
            hsaCoverage: p.hsaCoverage,
            employerHealthCoverageEndYear:
                endYear > retirement ? endYear : retirement + 5,
            socialSecurity: p.socialSecurity,
          )
        else
          p,
    ];
    deductions = [
      ...h.payrollDeductions,
      PayrollDeduction(
        id: newId('pd'),
        personId: person.id,
        label: 'Part-time health premium',
        kind: PayrollDeductionKind.healthPremium,
        annualAmount: premium,
        startYear: retirement,
        endYear: endYear > retirement ? endYear : retirement + 5,
      ),
    ];
    changes.add('Extended employer health coverage and added the premium, so '
        'the engine stops charging an ACA benchmark premium');
  } else {
    changes.add('No employer coverage, so the plan buys its own on the '
        'marketplace from $retirement');
  }

  return VariantOutcome(
    household:
        h.copyWith(incomeStreams: streams, people: people, payrollDeductions: deductions),
    scenario: s,
    changes: changes,
  );
}

Account _withContributionEnd(Account a, int endYear) => Account(
      id: a.id,
      personId: a.personId,
      label: a.label,
      kind: a.kind,
      taxTreatment: a.taxTreatment,
      limitFamily: a.limitFamily,
      balance: a.balance,
      costBasis: a.costBasis,
      rothContributionBasis: a.rothContributionBasis,
      rothFirstContributionYear: a.rothFirstContributionYear,
      employerId: a.employerId,
      allocationMode: a.allocationMode,
      assetAllocationId: a.assetAllocationId,
      allocationWeights: a.allocationWeights,
      isRestrictedPurpose: a.isRestrictedPurpose,
      targetBalanceMonths: a.targetBalanceMonths,
      beneficiaryId: a.beneficiaryId,
      contribution: Contribution(
        mode: a.contribution.mode,
        value: a.contribution.value,
        contributionBaseStreamIds: a.contribution.contributionBaseStreamIds,
        employerMatch: a.contribution.employerMatch,
        reducesFederalTaxableIncome: a.contribution.reducesFederalTaxableIncome,
        reducesStateTaxableIncome: a.contribution.reducesStateTaxableIncome,
        reducesFicaWages: a.contribution.reducesFicaWages,
        startYear: a.contribution.startYear,
        endYear: endYear,
        startMonth: a.contribution.startMonth,
        endMonth: a.contribution.endMonth,
      ),
    );

Assumptions _withWaterfall(Assumptions a, List<WaterfallStep> steps) =>
    Assumptions(
      generalInflationRate: a.generalInflationRate,
      safeWithdrawalRate: a.safeWithdrawalRate,
      contributionWaterfall: steps,
      withdrawalOrder: a.withdrawalOrder,
      highInterestDebtThresholdRate: a.highInterestDebtThresholdRate,
      includeSocialSecurity: a.includeSocialSecurity,
      capitalGainsRealizationRate: a.capitalGainsRealizationRate,
      projectionHorizonAge: a.projectionHorizonAge,
      acaMagiCeilingPercentOfFpl: a.acaMagiCeilingPercentOfFpl,
      pmiTerminationLtv: a.pmiTerminationLtv,
      assetSaleCostRate: a.assetSaleCostRate,
      taxYearId: a.taxYearId,
    );
