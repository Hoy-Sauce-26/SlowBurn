import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/adaptive_scaffold.dart';
import '../widgets/results_panel.dart';
import 'placeholder_screen.dart';

/// The frame every screen fills a slot in.
///
/// Stage 6 is the shell: the destinations are placeholders, and what is real is
/// the layout, the navigation, and the results panel wired to the engine.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _selected = 0;

  /// The order a household is entered in, which is also the order the guided
  /// flow will walk (§9's variants become presets over this same list).
  static final _destinations = <Destination>[
    Destination(
      label: 'Household',
      icon: Icons.people_outline,
      selectedIcon: Icons.people,
      build: () => const PlaceholderScreen(
        title: 'Household',
        blurb: 'Who is in the plan, when they were born, and how they file.',
      ),
    ),
    Destination(
      label: 'Income',
      icon: Icons.work_outline,
      selectedIcon: Icons.work,
      build: () => const PlaceholderScreen(
        title: 'Income',
        blurb: 'Salary, self-employment, rentals and pensions.',
      ),
    ),
    Destination(
      label: 'Accounts',
      icon: Icons.savings_outlined,
      selectedIcon: Icons.savings,
      build: () => const PlaceholderScreen(
        title: 'Accounts',
        blurb: 'Balances, contributions and the employer match behind them.',
      ),
    ),
    Destination(
      label: 'Spending',
      icon: Icons.receipt_long_outlined,
      selectedIcon: Icons.receipt_long,
      build: () => const PlaceholderScreen(
        title: 'Spending',
        blurb: 'What the household spends now and what changes at retirement.',
      ),
    ),
    Destination(
      label: 'Debts',
      icon: Icons.credit_card_outlined,
      selectedIcon: Icons.credit_card,
      build: () => const PlaceholderScreen(
        title: 'Debts and assets',
        blurb: 'Mortgages, loans, the house and the car.',
      ),
    ),
    Destination(
      label: 'Plan',
      icon: Icons.insights_outlined,
      selectedIcon: Icons.insights,
      build: () => const PlaceholderScreen(
        title: 'Plan',
        blurb: 'The projection, its bands, and how it has moved over time.',
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = Layout.of(constraints.maxWidth);

        // On a narrow window the results cannot share the screen with the
        // inputs, so they become a destination of their own rather than being
        // squeezed in beside them.
        final destinations = layout.showsResultsPanel
            ? _destinations
            : [
                ..._destinations,
                Destination(
                  label: 'Results',
                  icon: Icons.assessment_outlined,
                  selectedIcon: Icons.assessment,
                  build: () => const ResultsPanel(),
                ),
              ];

        final index = _selected.clamp(0, destinations.length - 1);
        return AdaptiveScaffold(
          title: 'Slow Burn',
          destinations: destinations,
          selectedIndex: index,
          onSelect: (i) => setState(() => _selected = i),
          results: const ResultsPanel(),
        );
      },
    );
  }
}
