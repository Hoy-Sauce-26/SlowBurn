import 'package:flutter/material.dart';

/// The one place breakpoints live.
///
/// Roamfree is a phone app with essentially no responsive code, so this is
/// designed rather than inherited. Scattering `MediaQuery` checks through seven
/// screens is how a codebase ends up responsive in some places and not others.
enum Layout {
  /// One column, bottom navigation, results on their own screen.
  compact,

  /// Two columns, navigation rail.
  medium,

  /// Rail, content, and a persistent results panel.
  expanded;

  static Layout of(double width) {
    if (width < 600) return Layout.compact;
    if (width < 1024) return Layout.medium;
    return Layout.expanded;
  }

  bool get showsRail => this != Layout.compact;
  bool get showsBottomBar => this == Layout.compact;

  /// The results panel is the desktop feature. A retirement plan is an argument
  /// between inputs and a result, and the interesting moment is watching the
  /// result move. On a phone they cannot share a screen, so every change is a
  /// round trip; here they can.
  bool get showsResultsPanel => this == Layout.expanded;
}

/// One place a user can navigate to.
class Destination {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function() build;

  const Destination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.build,
  });
}

class AdaptiveScaffold extends StatelessWidget {
  final List<Destination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// Shown beside the content on a wide window, and as its own destination on a
  /// narrow one.
  final Widget results;

  final String title;

  const AdaptiveScaffold({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
    required this.results,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = Layout.of(constraints.maxWidth);
        final content = destinations[selectedIndex].build();

        return Scaffold(
          appBar: AppBar(title: Text(title)),
          body: Row(
            children: [
              if (layout.showsRail)
                NavigationRail(
                  selectedIndex: selectedIndex,
                  onDestinationSelected: onSelect,
                  // A wide window has room to say what each icon means; a
                  // medium one does not, and a guessed icon is worse than a
                  // label the user has to hover for.
                  labelType: layout == Layout.expanded
                      ? NavigationRailLabelType.all
                      : NavigationRailLabelType.selected,
                  destinations: [
                    for (final d in destinations)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selectedIcon),
                        label: Text(d.label),
                      ),
                  ],
                ),
              Expanded(child: content),
              if (layout.showsResultsPanel)
                SizedBox(
                  width: 320,
                  child: Material(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    child: results,
                  ),
                ),
            ],
          ),
          bottomNavigationBar: layout.showsBottomBar
              ? NavigationBar(
                  selectedIndex: selectedIndex,
                  onDestinationSelected: onSelect,
                  destinations: [
                    for (final d in destinations)
                      NavigationDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selectedIcon),
                        label: d.label,
                      ),
                  ],
                )
              : null,
        );
      },
    );
  }
}
