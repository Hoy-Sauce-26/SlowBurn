import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/persistence.dart';
import '../widgets/adaptive_scaffold.dart';
import '../widgets/results_panel.dart';
import 'accounts_screen.dart';
import 'debts_screen.dart';
import 'household_screen.dart';
import 'income_screen.dart';
import 'plan_screen.dart';
import 'spending_screen.dart';

/// The frame every screen fills a slot in.
///
/// Stage 6 is the shell: the destinations are placeholders, and what is real is
/// the layout, the navigation, and the results panel wired to the engine.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Reads what was there last time, then keeps writing it back. There is
    // nowhere else the plan exists (§1.4), so an unsaved edit is a lost one.
    ref.read(persistenceProvider).start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Closing the window or switching away should not lose the last few
    // seconds of typing, so the debounce is skipped here.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      ref.read(persistenceProvider).save();
    }
  }

  /// The order a household is entered in, which is also the order the guided
  /// flow will walk (§9's variants become presets over this same list).
  static final _destinations = <Destination>[
    Destination(
      label: 'Household',
      icon: Icons.people_outline,
      selectedIcon: Icons.people,
      build: () => const HouseholdScreen(),
    ),
    Destination(
      label: 'Income',
      icon: Icons.work_outline,
      selectedIcon: Icons.work,
      build: () => const IncomeScreen(),
    ),
    Destination(
      label: 'Accounts',
      icon: Icons.savings_outlined,
      selectedIcon: Icons.savings,
      build: () => const AccountsScreen(),
    ),
    Destination(
      label: 'Spending',
      icon: Icons.receipt_long_outlined,
      selectedIcon: Icons.receipt_long,
      build: () => const SpendingScreen(),
    ),
    Destination(
      label: 'Debts',
      icon: Icons.credit_card_outlined,
      selectedIcon: Icons.credit_card,
      build: () => const DebtsScreen(),
    ),
    Destination(
      label: 'Plan',
      icon: Icons.insights_outlined,
      selectedIcon: Icons.insights,
      build: () => const PlanScreen(),
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
