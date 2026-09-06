import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/flag_placement.dart';
import '../services/providers.dart';
import 'results_panel.dart';

/// The flags belonging to one screen, shown at the top of it.
///
/// Collapsed to a line by default, since a plan with six caveats should still
/// be usable. Every one of these is something the model knows it is
/// approximating, and a plan is worth less without them.
class FlagBanner extends ConsumerStatefulWidget {
  final FlagHome home;

  /// Screens built on [EntityList] pad their own content, and the plan screen
  /// pads the whole list, so the banner should not do it twice.
  final bool inset;

  const FlagBanner({super.key, required this.home, this.inset = true});

  @override
  ConsumerState<FlagBanner> createState() => _FlagBannerState();
}

class _FlagBannerState extends ConsumerState<FlagBanner> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final flags = flagsFor(widget.home, ref.watch(flagsProvider));
    if (flags.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final sorted = flags.toList()..sort();

    return Padding(
      padding: EdgeInsets.fromLTRB(
          widget.inset ? 24 : 0, 0, widget.inset ? 24 : 0, 8),
      child: Card(
        color: theme.colorScheme.tertiaryContainer,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 18,
                        color: theme.colorScheme.onTertiaryContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        sorted.length == 1
                            ? flagLabels[sorted.first] ?? sorted.first
                            : '${sorted.length} things to know about this part '
                                'of the plan',
                        style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.onTertiaryContainer),
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ],
                ),
                if (_expanded)
                  Padding(
                    padding: const EdgeInsets.only(top: 8, left: 26),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final flag in sorted)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  flagLabels[flag] ?? flag,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                      color: theme
                                          .colorScheme.onTertiaryContainer),
                                ),
                                Text(
                                  flagExplanations[flag] ?? '',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme
                                          .colorScheme.onTertiaryContainer),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
