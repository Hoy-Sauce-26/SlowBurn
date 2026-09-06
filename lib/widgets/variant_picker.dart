import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/providers.dart';
import '../services/variants.dart';
import 'entity_list.dart';
import 'fields.dart';

/// §9's variants offered as a starting point, never as a stored mode.
///
/// The picker writes the recipe and gets out of the way. Nothing downstream
/// branches on which one was chosen, and the household afterwards is
/// indistinguishable from one a user built by hand.
Future<void> showVariantPicker(BuildContext context, WidgetRef ref) =>
    showEditor<void>(
      context,
      title: 'Shape the plan',
      build: (context) => _VariantPicker(ref: ref),
    );

class _VariantPicker extends StatefulWidget {
  final WidgetRef ref;
  const _VariantPicker({required this.ref});

  @override
  State<_VariantPicker> createState() => _VariantPickerState();
}

class _VariantPickerState extends State<_VariantPicker> {
  FireVariant? _chosen;
  var _traditionalAge = 67;
  var _baristaPay = Money.dollars(30000);
  var _baristaPremium = Money.dollars(4800);
  var _baristaEndYear = 0;
  VariantOutcome? _preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Each of these is a different way to stop working, and each is just '
          'a set of entries. Nothing is locked in: you can change any of it '
          'afterwards.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        for (final variant in FireVariant.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _VariantCard(
              variant: variant,
              selected: _chosen == variant,
              onTap: () => setState(() {
                _chosen = variant;
                _preview = null;
              }),
            ),
          ),
        if (_chosen == FireVariant.traditional) ...[
          const SizedBox(height: 12),
          YearField(
            label: 'Retire at',
            helper: 'The engine stops solving for a date',
            initial: _traditionalAge,
            onChanged: (v) => _traditionalAge = v ?? _traditionalAge,
          ),
        ],
        if (_chosen == FireVariant.barista) ...[
          const SizedBox(height: 12),
          FieldRow([
            MoneyField(
              label: 'Part-time pay',
              helper: 'A year, in today\'s dollars',
              initial: _baristaPay,
              onChanged: (v) => _baristaPay = v,
            ),
            MoneyField(
              label: 'Health premium',
              helper: 'Blank buys cover on the marketplace instead',
              initial: _baristaPremium,
              onChanged: (v) => _baristaPremium = v,
            ),
          ]),
          YearField(
            label: 'Work until',
            helper: 'Blank runs it five years',
            initial: _baristaEndYear == 0 ? null : _baristaEndYear,
            onChanged: (v) => _baristaEndYear = v ?? 0,
          ),
        ],
        if (_preview != null) ...[
          const SizedBox(height: 16),
          _Outcome(outcome: _preview!),
        ],
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            if (_preview == null)
              FilledButton(
                onPressed: _chosen == null ? null : _previewIt,
                child: const Text('Show me what changes'),
              )
            else if (_preview!.blocked == null)
              FilledButton(
                onPressed: _applyIt,
                child: const Text('Apply'),
              ),
          ],
        ),
      ],
    );
  }

  void _previewIt() {
    final outcome = applyVariant(
      _chosen!,
      household: widget.ref.read(householdProvider),
      scenario: widget.ref.read(scenarioProvider),
      currentYear: DateTime.now().year,
      traditionalAge: _traditionalAge,
      baristaPay: _baristaPay,
      baristaPremium: _baristaPremium,
      baristaEndYear: _baristaEndYear,
    );
    setState(() => _preview = outcome);
  }

  void _applyIt() {
    final outcome = _preview!;
    widget.ref.read(householdProvider.notifier).replace(outcome.household);
    widget.ref.read(scenarioProvider.notifier).replace(outcome.scenario);
    Navigator.of(context).pop();
  }
}

class _VariantCard extends StatelessWidget {
  final FireVariant variant;
  final bool selected;
  final VoidCallback onTap;

  const _VariantCard({
    required this.variant,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: selected ? theme.colorScheme.secondaryContainer : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(variant.title, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(variant.blurb, style: theme.textTheme.bodySmall),
              if (variant.contrast != null) ...[
                const SizedBox(height: 6),
                Text(
                  variant.contrast!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
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

/// What the recipe would do, shown before it does it. A preset that changes six
/// things silently is worse than the six edits it saves.
class _Outcome extends StatelessWidget {
  final VariantOutcome outcome;
  const _Outcome({required this.outcome});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (outcome.blocked != null) {
      return Card(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, color: theme.colorScheme.tertiary),
              const SizedBox(width: 12),
              Expanded(
                  child: Text(outcome.blocked!,
                      style: theme.textTheme.bodySmall)),
            ],
          ),
        ),
      );
    }
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This will', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final change in outcome.changes)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('· '),
                    Expanded(
                        child:
                            Text(change, style: theme.textTheme.bodySmall)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
