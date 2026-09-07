import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../services/readiness.dart';

/// What stands where the numbers go until the plan is ready to be read.
///
/// It is a progress bar and a list rather than an apology, because the point is
/// that a plan is something you build up and can see the shape of, not a form
/// that is either valid or not.
class SetupChecklist extends ConsumerWidget {
  /// Where the button leads. Null hides it, for the places that are already
  /// showing the flow.
  final VoidCallback? onContinue;

  const SetupChecklist({super.key, this.onContinue});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final household = ref.watch(householdProvider);
    final setup = ref.watch(setupProgressProvider);

    final done = setup.doneCount(household);
    final total = setup.stepCount;
    final next = setup.nextFor(household);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              done == total ? 'Your plan is ready' : 'Building your plan',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text('$done of $total', style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : done / total,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 16),
            for (final step in SetupStep.values.where((s) => s.gates))
              _StepRow(
                step: step,
                done: setup.isDone(step, household),
                isNext: step == next,
                summary: step.summaryIn(household),
                passed: setup.passed.contains(step),
              ),
            const SizedBox(height: 12),
            Text(
              done == total
                  ? 'Nothing is worked out until you say so. Numbers appear '
                      'once you do.'
                  : 'No dates or targets yet. A plan missing '
                      '${next?.title.toLowerCase() ?? 'a piece'} would answer '
                      'the wrong question.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (onContinue != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: onContinue,
                  child: Text(done == 0
                      ? 'Start'
                      : done == total
                          ? 'Show me my plan'
                          : 'Continue'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final SetupStep step;
  final bool done;
  final bool isNext;
  final bool passed;
  final String? summary;

  const _StepRow({
    required this.step,
    required this.done,
    required this.isNext,
    required this.passed,
    this.summary,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = done
        ? theme.colorScheme.primary
        : isNext
            ? theme.colorScheme.onSurface
            : theme.colorScheme.outline;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            done ? Icons.check_circle : Icons.circle_outlined,
            size: 18,
            color: colour,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colour,
                    fontWeight: isNext ? FontWeight.w600 : null,
                  ),
                ),
                if (summary != null)
                  Text(summary!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant))
                else if (passed)
                  Text('none',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
