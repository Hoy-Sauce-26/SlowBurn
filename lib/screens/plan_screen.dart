import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/flag_placement.dart';
import '../services/providers.dart';
import '../services/readiness.dart';
import '../widgets/fields.dart';
import '../widgets/flag_banner.dart';
import '../widgets/metric_card.dart';
import '../widgets/net_worth_chart.dart';
import '../widgets/setup_checklist.dart';
import '../widgets/variant_picker.dart';
import 'setup_screen.dart';

/// §8 and §9. The answer, its bands, and the assumptions behind it.
///
/// The three bands sit together here rather than in the results panel: one
/// headline is what a glance is for, and the spread is a comparison the user
/// asks for.
class PlanScreen extends ConsumerWidget {
  const PlanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final projection = ref.watch(projectionProvider);
    final scenario = ref.watch(scenarioProvider);
    final notifier = ref.read(scenarioProvider.notifier);
    final setup = ref.watch(setupProgressProvider);
    final household = ref.watch(householdProvider);

    // Until the plan is declared ready this screen is the setup path and
    // nothing else. Offering scenarios to shape a plan that has no numbers
    // behind it would be asking someone to steer before the engine is on.
    if (!setup.showsProjection(household)) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The checklist carries its own heading and its progress, so
                  // a second title above it would only repeat itself.
                  Text(
                    'What your plan still needs, in the order worth answering '
                    'it. Nothing is worked out until you say it is ready.',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  SetupChecklist(
                    onContinue: () => SetupFlow.open(context,
                        at: setup.nextFor(household) ?? SetupStep.spending),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Plan', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'The projection, its bands, and the assumptions behind it.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => SetupFlow.open(context, at: SetupStep.refinements),
          icon: const Icon(Icons.checklist),
          label: const Text('Walk through the plan again'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => showVariantPicker(context, ref),
          icon: const Icon(Icons.auto_awesome_outlined),
          label: const Text('Shape the plan'),
        ),
        const SizedBox(height: 8),
        Text(
          'Coast, Barista, traditional retirement: each is a set of entries '
          'rather than a mode, so you can change any of it afterwards.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        projection.when(
          loading: () =>
              const Center(child: CircularProgressIndicator()),
          error: (e, _) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('$e'),
            ),
          ),
          data: (bands) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NetWorthChart(bands: bands),
              const SizedBox(height: 24),
              _Bands(bands: bands),
            ],
          ),
        ),
        const SizedBox(height: 32),
        const FlagBanner(home: FlagHome.plan, inset: false),
        const _WithdrawalRateAdvice(),
        const SizedBox(height: 8),
        Text('Assumptions', style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        FieldRow([
          PercentField(
            key: ValueKey(scenario.assumptions.safeWithdrawalRate),
            label: 'Safe withdrawal rate',
            helper: 'The share of the pot you spend in the first year of '
                'retirement, which everything else is measured against.',
            initial: scenario.assumptions.safeWithdrawalRate,
            onChanged: (v) => notifier.replace(_with(
                scenario, (a) => _copy(a, safeWithdrawalRate: v))),
          ),
          YearField(
            label: 'Plan to age',
            helper: 'Against the youngest person',
            initial: scenario.assumptions.projectionHorizonAge,
            onChanged: (v) => v == null
                ? null
                : notifier.replace(_with(
                    scenario, (a) => _copy(a, projectionHorizonAge: v))),
          ),
        ]),
        FieldRow([
          PercentField(
            label: 'General inflation',
            helper: 'Deflates thresholds statute never indexed',
            initial: scenario.assumptions.generalInflationRate,
            onChanged: (v) => notifier.replace(_with(
                scenario, (a) => _copy(a, generalInflationRate: v))),
          ),
          PercentField(
            label: 'High-interest debt above',
            helper: 'Real, so it compares against real returns',
            initial: scenario.assumptions.highInterestDebtThresholdRate,
            onChanged: (v) => notifier.replace(_with(scenario,
                (a) => _copy(a, highInterestDebtThresholdRate: v))),
          ),
        ]),
        SwitchListTile(
          title: const Text('Count on Social Security'),
          subtitle: const Text(
              'Off answers "what if it is not there at all"'),
          value: scenario.assumptions.includeSocialSecurity,
          onChanged: (v) => notifier.replace(
              _with(scenario, (a) => _copy(a, includeSocialSecurity: v))),
        ),
        const SizedBox(height: 24),
        const _Returns(),
        const SizedBox(height: 24),
        const _RetirementHoldings(),
        const SizedBox(height: 24),
        const _Appreciation(),
      ],
    );
  }
}

/// Where the withdrawal rate comes from, since nobody knows theirs and the
/// number most people arrive with is the answer to a different question.
///
/// The suggestion reads the retirement year the plan has already solved rather
/// than solving one of its own. Doing it inside the engine would be circular:
/// the rate sets the FIRE number, the FIRE number sets the retirement year,
/// and the retirement year is what says how long the money has to last.
class _WithdrawalRateAdvice extends ConsumerWidget {
  const _WithdrawalRateAdvice();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scenario = ref.watch(scenarioProvider);
    final notifier = ref.read(scenarioProvider.notifier);
    final household = ref.watch(householdProvider);
    final projection = ref.watch(projectionProvider);

    final retiresIn = projection.maybeWhen(
      data: (bands) => bands.expected.retirementYear,
      orElse: () => null,
    );
    if (retiresIn == null) return const SizedBox.shrink();

    final end = horizonYear(
        household, scenario.assumptions, DateTime.now().year);
    final years = end - retiresIn + 1;
    if (years <= 0) return const SizedBox.shrink();

    final suggested = suggestedWithdrawalRate(years);
    final current = scenario.assumptions.safeWithdrawalRate;
    final matches = (current - suggested).abs() < 1e-9;

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Card(
        color: matches
            ? theme.colorScheme.surfaceContainerHighest
            : theme.colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This plan retires in $retiresIn and runs to $end, so the '
                'money has to last $years years.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text(
                matches
                    ? '${formatPercent(suggested)} is the usual withdrawal '
                        'rate for a retirement that long, which is what you '
                        'have.'
                    : '${formatPercent(suggested)} is the usual withdrawal '
                        'rate for a retirement that long. The 4% everybody '
                        'quotes is a finding about thirty years, and a longer '
                        'one runs out at it.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (!matches) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    onPressed: () => notifier.replace(_with(scenario,
                        (a) => _copy(a, safeWithdrawalRate: suggested))),
                    child: Text(
                        'Use a ${formatPercent(suggested)} withdrawal rate'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// What each holding is assumed to do, which is the largest single lever in
/// the projection and was previously only visible in the code.
class _Returns extends ConsumerWidget {
  const _Returns();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final classes = ref.watch(assetClassesProvider);
    final notifier = ref.read(assetClassesProvider.notifier);

    AssetClass edited(AssetClass c,
            {Rate? expected, Rate? pessimistic, Rate? optimistic}) =>
        AssetClass(
          id: c.id,
          label: c.label,
          expectedRealReturn: expected ?? c.expectedRealReturn,
          pessimisticRealReturn: pessimistic ?? c.pessimisticRealReturn,
          optimisticRealReturn: optimistic ?? c.optimisticRealReturn,
          incomeYield: c.incomeYield,
          qualifiedIncomeFraction: c.qualifiedIncomeFraction,
        );

    void save(AssetClass replacement) => notifier.replace([
          for (final c in classes) c.id == replacement.id ? replacement : c,
        ]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('What each holding earns',
                  style: theme.textTheme.titleMedium),
            ),
            _Reset(
              // Guessing at returns is how somebody learns what the bands do,
              // and a way back is what makes guessing safe.
              changed: !_sameReturns(classes, AssetClass.defaults),
              onReset: () => notifier.replace(AssetClass.defaults),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Real rates, above inflation. The three columns are the three bands '
          'the chart draws, so widening them widens the spread of futures.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        for (final c in classes)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(assetClassName(c),
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    FieldRow([
                      PercentField(
                        label: 'Pessimistic',
                        initial: c.pessimisticRealReturn,
                        onChanged: (v) => save(edited(c, pessimistic: v)),
                      ),
                      PercentField(
                        label: 'Expected',
                        initial: c.expectedRealReturn,
                        onChanged: (v) => save(edited(c, expected: v)),
                      ),
                      PercentField(
                        label: 'Optimistic',
                        initial: c.optimisticRealReturn,
                        onChanged: (v) => save(edited(c, optimistic: v)),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// What everything moves into at retirement, set once for the whole plan.
///
/// Per account it was technically adjustable and practically invisible: nobody
/// opens six account editors to answer one question about their whole
/// portfolio. This writes the answer to every account that can hold it, which
/// is what somebody means when they say "I will be in bonds by then".
class _RetirementHoldings extends ConsumerWidget {
  const _RetirementHoldings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final classes = ref.watch(assetClassesProvider);
    final household = ref.watch(householdProvider);
    final notifier = ref.read(householdProvider.notifier);

    final movable =
        household.accounts.where((a) => !a.kind.isCash).toList();
    if (movable.isEmpty) return const SizedBox.shrink();

    // The shared answer, or null where accounts disagree, which they can only
    // do by having been set one at a time.
    final ids = movable.map((a) => a.retirementAllocationId).toSet();
    final shared = ids.length == 1 ? ids.single : null;
    final mixed = ids.length > 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('What you hold once retired', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Selling shares into a bad year is what sends people back to work, '
          'so most plans hold less of them by retirement. Leave everything '
          'where it is and the projection earns a working-life return through '
          'the whole of a retirement, which is the optimistic answer.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        SearchableField<AssetClass>(
          key: ValueKey('$shared$mixed'),
          label: 'Move investments into',
          helper: mixed
              ? 'Your accounts differ. Choosing here sets all '
                  '${movable.length} of them.'
              : 'Applies to all ${movable.length} of your invested accounts. '
                  'Cash stays where it is.',
          values: classes,
          value: classes.where((c) => c.id == shared).firstOrNull,
          noneLabel: mixed ? 'Mixed' : 'Leave everything where it is',
          describe: assetClassName,
          onChanged: (c) {
            for (final account in movable) {
              notifier.saveAccount(account.withRetirementAllocation(c?.id));
            }
          },
        ),
      ],
    );
  }
}

/// What property does, which sets the suggestion every new asset starts from.
class _Appreciation extends ConsumerWidget {
  const _Appreciation();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scenario = ref.watch(scenarioProvider);
    final notifier = ref.read(scenarioProvider.notifier);
    final rates = scenario.assumptions.assetAppreciationByCategory;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('What property does',
                  style: theme.textTheme.titleMedium),
            ),
            _Reset(
              changed: !_sameRates(
                  rates, Assumptions.defaultAssetAppreciation),
              onReset: () => notifier.replace(_with(
                  scenario,
                  (a) => _copy(a,
                      assetAppreciation:
                          Assumptions.defaultAssetAppreciation))),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Real rates again, so zero means it holds its value and nothing '
          'more. These are the starting point for anything you add; an asset '
          'already entered keeps the rate it was saved with.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        for (final category in AssetCategory.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: PercentField(
              label: humanise(category.name),
              initial: rates[category] ?? 0,
              onChanged: (v) => notifier.replace(_with(
                  scenario,
                  (a) => _copy(a, assetAppreciation: {...rates, category: v}))),
            ),
          ),
      ],
    );
  }
}

class _Bands extends StatelessWidget {
  final Band<BandResult> bands;
  const _Bands({required this.bands});

  @override
  Widget build(BuildContext context) {
    final rows = <(String, BandResult)>[
      ('Pessimistic', bands.pessimistic),
      ('Expected', bands.expected),
      ('Optimistic', bands.optimistic),
    ];
    return Column(
      children: [
        for (final (label, result) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: MetricCard(
                    icon: Icons.event_available_outlined,
                    label: '$label retirement',
                    value: '${result.retirementYear ?? ''}',
                    unavailable: result.retirementYear == null
                        ? 'Not reachable'
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: MetricCard(
                    icon: Icons.flag_outlined,
                    label: 'FIRE number',
                    value: result.fireNumber == null
                        ? ''
                        : formatMoneyCompact(result.fireNumber!),
                    unavailable: result.fireNumber == null ? '—' : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

Scenario _with(Scenario s, Assumptions Function(Assumptions) edit) => Scenario(
      id: s.id,
      householdId: s.householdId,
      label: s.label,
      assumptions: edit(s.assumptions),
    );

/// `Assumptions` has no copyWith in the engine, since nothing there needs one:
/// a scenario is written whole. The UI does need one, so it lives here.
Assumptions _copy(
  Assumptions a, {
  Rate? generalInflationRate,
  Rate? safeWithdrawalRate,
  Rate? highInterestDebtThresholdRate,
  bool? includeSocialSecurity,
  int? projectionHorizonAge,
  Map<AssetCategory, Rate>? assetAppreciation,
}) =>
    Assumptions(
      generalInflationRate: generalInflationRate ?? a.generalInflationRate,
      safeWithdrawalRate: safeWithdrawalRate ?? a.safeWithdrawalRate,
      contributionWaterfall: a.contributionWaterfall,
      withdrawalOrder: a.withdrawalOrder,
      highInterestDebtThresholdRate:
          highInterestDebtThresholdRate ?? a.highInterestDebtThresholdRate,
      includeSocialSecurity:
          includeSocialSecurity ?? a.includeSocialSecurity,
      capitalGainsRealizationRate: a.capitalGainsRealizationRate,
      projectionHorizonAge: projectionHorizonAge ?? a.projectionHorizonAge,
      acaMagiCeilingPercentOfFpl: a.acaMagiCeilingPercentOfFpl,
      pmiTerminationLtv: a.pmiTerminationLtv,
      assetSaleCostRate: a.assetSaleCostRate,
      assetAppreciationByCategory:
          assetAppreciation ?? a.assetAppreciationByCategory,
      taxYearId: a.taxYearId,
    );

/// Offered only once something has actually moved, so it is a way back rather
/// than a button that does nothing most of the time.
class _Reset extends StatelessWidget {
  final bool changed;
  final VoidCallback onReset;

  const _Reset({required this.changed, required this.onReset});

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: changed ? onReset : null,
        icon: const Icon(Icons.restart_alt, size: 18),
        label: const Text('Reset to defaults'),
      );
}

bool _sameReturns(List<AssetClass> a, List<AssetClass> b) {
  if (a.length != b.length) return false;
  for (final c in b) {
    final mine = a.where((x) => x.id == c.id).firstOrNull;
    if (mine == null ||
        mine.expectedRealReturn != c.expectedRealReturn ||
        mine.pessimisticRealReturn != c.pessimisticRealReturn ||
        mine.optimisticRealReturn != c.optimisticRealReturn) {
      return false;
    }
  }
  return true;
}

bool _sameRates(Map<AssetCategory, Rate> a, Map<AssetCategory, Rate> b) =>
    AssetCategory.values.every((c) => a[c] == b[c]);
