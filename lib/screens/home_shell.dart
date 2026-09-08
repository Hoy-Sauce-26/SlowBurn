import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/persistence.dart';
import '../widgets/adaptive_scaffold.dart';
import '../widgets/results_panel.dart';
import 'accounts_screen.dart';
import 'breakdown_screen.dart';
import 'housing_screen.dart';
import 'property_screen.dart';
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
  /// Opens on Plan, which is where the answer lives once there is one and the
  /// list of what is still missing until then. Landing on a form asks somebody
  /// to fill it in without saying why.
  int _selected = _planIndex;

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
      label: 'Housing',
      icon: Icons.holiday_village_outlined,
      selectedIcon: Icons.holiday_village,
      build: () => const HousingScreen(),
    ),
    Destination(
      // Assets live here too, and a page called Debts that holds the house is
      // the kind of label somebody trusts once.
      label: 'Property',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
      build: () => const PropertyScreen(),
    ),
    Destination(
      // The same numbers as Plan, asked in the order somebody thinks in.
      label: 'Breakdown',
      icon: Icons.question_answer_outlined,
      selectedIcon: Icons.question_answer,
      build: () => const BreakdownScreen(),
    ),
    Destination(
      label: 'Plan',
      icon: Icons.insights_outlined,
      selectedIcon: Icons.insights,
      build: () => const PlanScreen(),
    ),
  ];

  static int get _planIndex =>
      _destinations.indexWhere((d) => d.label == 'Plan');

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
          // The Plan screen carries the checklist itself while a plan is being
          // built, so the panel beside it does not say the same thing twice.
          results: ResultsPanel(showsSetup: index != _planIndex),
        );
      },
    );
  }
}
