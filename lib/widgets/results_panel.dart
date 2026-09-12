import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../screens/setup_screen.dart';
import '../services/providers.dart';
import '../services/readiness.dart';
import 'metric_card.dart';
import 'setup_checklist.dart';

/// The desktop feature: the answer, beside the inputs, moving as they change.
///
/// Shows the expected band, because one headline is what a glance is for. The
/// other two are a comparison the user asks for rather than one they are
/// handed.
class ResultsPanel extends ConsumerWidget {
  /// Whether to carry the checklist while a plan is still being built. False
  /// where the main view is already showing it.
  final bool showsSetup;

  const ResultsPanel({super.key, this.showsSetup = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projection = ref.watch(projectionProvider);
    final findings = ref.watch(findingsProvider);
    final flags = ref.watch(flagsProvider);
    final building = !ref
        .watch(setupProgressProvider)
        .showsProjection(ref.watch(householdProvider));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Your plan', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        if (building && showsSetup)
          SetupChecklist(
            onContinue: () => SetupFlow.open(
              context,
              at: ref.read(setupProgressProvider).nextFor(
                    ref.read(householdProvider),
                  ) ??
                  SetupStep.spending,
            ),
          )
        else if (building)
          const _NothingYet(
              reason: 'Nothing is worked out until you say the plan is ready.')
        else
          projection.when(
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (error, _) => _NothingYet(reason: '$error'),
            data: (bands) => _Headlines(result: bands.expected),
          ),
        if (findings.isNotEmpty) ...[
          const SizedBox(height: 24),
          _Findings(findings: findings),
        ],
        if (flags.isNotEmpty) ...[
          const SizedBox(height: 24),
          _Flags(flags: flags),
        ],
      ],
    );
  }
}

class _Headlines extends StatelessWidget {
  final BandResult result;
  const _Headlines({required this.result});

  @override
  Widget build(BuildContext context) {
    final money = NumberFormat.compactCurrency(symbol: r'$', decimalDigits: 2);
    final year = result.retirementYear;

    return Column(
      children: [
        MetricCard(
          icon: Icons.event_available_outlined,
          label: 'Retirement year',
          value: '${year ?? ''}',
          unavailable: year == null ? 'Not yet reachable' : null,
        ),
        const SizedBox(height: 8),
        MetricCard(
          icon: Icons.flag_outlined,
          label: 'FIRE number',
          value: result.fireNumber == null
              ? ''
              : money.format(result.fireNumber!.dollars),
          unit: 'to retire on',
          unavailable: result.fireNumber == null ? '—' : null,
        ),
        const SizedBox(height: 8),
        // §9.4's inverse: what the plan as entered will actually support. The
        // headline for a household whose date is already fixed.
        MetricCard(
          icon: Icons.payments_outlined,
          label: 'Sustainable spending',
          value: result.sustainableLevelSpending == null
              ? ''
              : money.format(result.sustainableLevelSpending!.dollars),
          unit: 'a year',
          unavailable: result.sustainableLevelSpending == null ? '—' : null,
        ),
      ],
    );
  }
}

class _NothingYet extends StatelessWidget {
  final String reason;
  const _NothingYet({required this.reason});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.hourglass_empty, color: theme.colorScheme.outline),
            const SizedBox(height: 8),
            Text('No projection yet', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(reason, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// §12's findings, which warn rather than block wherever they can.
class _Findings extends StatelessWidget {
  final List<Finding> findings;
  const _Findings({required this.findings});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Worth fixing', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        for (final finding in findings)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  finding.severity == Severity.blocking
                      ? Icons.error_outline
                      : Icons.warning_amber_outlined,
                  size: 18,
                  color: finding.severity == Severity.blocking
                      ? theme.colorScheme.error
                      : theme.colorScheme.tertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(finding.message,
                      style: theme.textTheme.bodySmall),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The engine saying its answer has a caveat. Every one of these is a thing the
/// model knows it is approximating, and a plan is worth less without them.
class _Flags extends StatelessWidget {
  final Set<String> flags;
  const _Flags({required this.flags});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('About this projection', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final flag in flags.toList()..sort())
              Tooltip(
                message: flagExplanations[flag] ?? flag,
                child: Chip(
                  label: Text(flagLabels[flag] ?? flag),
                  labelStyle: theme.textTheme.labelSmall,
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Short names, since a flag identifier is engine vocabulary.
const flagLabels = <String, String>{
  'shortfall': 'Ran short',
  'bufferDepleted': 'Buffer used',
  'contributionLimitExceeded': 'Over a limit',
  'waterfallNotConverged': 'Allocation unsettled',
  'bridgeGapDetected': 'Bridge gap',
  'magiCeilingBreached': 'Subsidy lost',
  'acaMagiBelowSubsidyFloor': 'No health subsidy',
  'retirementSpendingNotLevel': 'Spending changes',
  'rothRolloverAssumed': 'Roth rollover assumed',
  'earningsTestNotModeled': 'Earnings test',
  'qbiLimitNotModeled': 'QBI limits',
  'unvestedMatchAtRisk': 'Match unvested',
  'rothIraIncomeLimitReached': 'Roth income limit',
  'hsaContributionsStoppedAtMedicare': 'HSA stopped at 65',
  'escrowDiffersFromInferred': 'Escrow disagrees',
  'noHousingCost': 'Nowhere to live',
  'payoffLeavesResidualEscrow': 'Escrow after payoff',
  'derivedPayoffDiffersFromTerm': 'Payoff disagrees',
  'possibleDoubleCount': 'Possible double count',
  'filingStatusNoLongerQualifies': 'Filing status',
  'swrHorizonMismatch': 'Withdrawal rate',
  'electionExceededRealizedSurplus': 'Over-elected',
  'education529LeftOver': 'Left in a 529',
};

/// What each one means, in the user's terms rather than the engine's.
const flagExplanations = <String, String>{
  'shortfall': 'A year could not be funded from any source.',
  'bufferDepleted': 'The emergency fund was drawn below its target.',
  'contributionLimitExceeded':
      'A contribution was capped at the legal limit for that account.',
  'waterfallNotConverged':
      'The allocation was still moving when the engine stopped iterating.',
  'bridgeGapDetected':
      'Reaching money before 59½ may fall short. A Roth conversion ladder, a '
          '72(t) schedule, or the Rule of 55 could close this, and none is '
          'modelled here.',
  'magiCeilingBreached':
      'Funding the year required income that costs some ACA subsidy.',
  'acaMagiBelowSubsidyFloor':
      'Help with health insurance starts at the federal poverty line, and in '
          'some years this plan earns less than that. Under the line the '
          'marketplace pays nothing at all: in states that expanded Medicaid '
          'you would be covered by that instead, and in the states that did '
          'not you would be buying at full price.\n\n'
          'Early retirees hit this by keeping taxable income very low, which '
          'is otherwise the right instinct. Taking a little more on purpose, '
          'through a Roth conversion or by realising some gains, often costs '
          'less in tax than the subsidy it buys back.\n\n'
          'This app cannot model that fix yet, so it is telling you about a '
          'real cost it has already priced rather than one you can adjust '
          'here. The premium in these years is the full one.',
  'retirementSpendingNotLevel':
      'Spending changes across retirement, so the plan is sized on the level '
          'equivalent rather than the first year.',
  'rothRolloverAssumed':
      'A workplace Roth balance is assumed rolled to a Roth IRA at retirement.',
  'earningsTestNotModeled':
      'Claiming before full retirement age while working: the real programme '
          'would withhold part of the benefit.',
  'qbiLimitNotModeled':
      'Above the threshold the §199A wage and service-business limits apply '
          'and are not modelled, so the deduction is overstated.',
  'unvestedMatchAtRisk':
      'Employer match is counted in full though some of it is unvested.',
  'rothIraIncomeLimitReached':
      'Income is above the Roth IRA limit; the backdoor route is not modelled.',
  'hsaContributionsStoppedAtMedicare':
      'Medicare enrolment ends HSA eligibility at 65.',
  'noHousingCost':
      'For part of this plan the household owns no home and pays nothing for '
          'housing, so it is being projected as though shelter were free. '
          'Selling a house is one field; where you live afterwards is '
          'another.',
  'escrowDiffersFromInferred':
      'The entered escrow disagrees with what the payment implies.',
  'payoffLeavesResidualEscrow':
      'Tax and insurance continue after the mortgage is paid off.',
  'derivedPayoffDiffersFromTerm':
      'The balance and payment imply a different payoff date than the term.',
  'possibleDoubleCount':
      'An expense line may restate something already counted.',
  'filingStatusNoLongerQualifies':
      'Head of household needs a dependent; computed as single this year.',
  'swrHorizonMismatch':
      'This withdrawal rate is high for a retirement this long.',
  'electionExceededRealizedSurplus':
      'More was withheld from pay than the year turned out to support.',
  'education529LeftOver':
      'A 529 still holds money after the last education bill in this plan. '
          'Spent on anything else, its growth is taxed and pays a 10% '
          'penalty. Putting in less, or adding a younger child\'s '
          'education, would use it.',
};
