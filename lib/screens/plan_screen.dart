import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../widgets/fields.dart';
import '../widgets/metric_card.dart';

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
          data: (bands) => _Bands(bands: bands),
        ),
        const SizedBox(height: 32),
        Text('Assumptions', style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        FieldRow([
          PercentField(
            label: 'Safe withdrawal rate',
            helper: 'A longer retirement needs a lower rate',
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
      taxYearId: a.taxYearId,
    );
