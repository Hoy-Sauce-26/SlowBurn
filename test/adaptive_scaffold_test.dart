import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slow_burn/widgets/adaptive_scaffold.dart';

void main() {
  group('breakpoints live in one place', () {
    test('the three layouts split at 600 and 1024', () {
      expect(Layout.of(375), Layout.compact);
      expect(Layout.of(599), Layout.compact);
      expect(Layout.of(600), Layout.medium);
      expect(Layout.of(1023), Layout.medium);
      expect(Layout.of(1024), Layout.expanded);
      expect(Layout.of(1920), Layout.expanded);
    });

    test('only the widest layout can show inputs and results together', () {
      expect(Layout.compact.showsResultsPanel, isFalse);
      expect(Layout.medium.showsResultsPanel, isFalse);
      expect(Layout.expanded.showsResultsPanel, isTrue);
    });

    test('a rail and a bottom bar are never both shown', () {
      for (final layout in Layout.values) {
        expect(layout.showsRail && layout.showsBottomBar, isFalse);
      }
    });
  });

  group('the frame at each size', () {
    Widget frame() => MaterialApp(
          home: AdaptiveScaffold(
            title: 'Slow Burn',
            selectedIndex: 0,
            onSelect: (_) {},
            results: const Text('RESULTS'),
            destinations: [
              Destination(
                label: 'Household',
                icon: Icons.people_outline,
                selectedIcon: Icons.people,
                build: () => const Text('CONTENT'),
              ),
              Destination(
                label: 'Income',
                icon: Icons.work_outline,
                selectedIcon: Icons.work,
                build: () => const Text('OTHER'),
              ),
            ],
          ),
        );

    Future<void> pumpAt(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(frame());
      await tester.pump();
    }

    testWidgets('a phone gets a bottom bar and no results beside the content',
        (tester) async {
      await pumpAt(tester, const Size(390, 844));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('RESULTS'), findsNothing);
      expect(find.text('CONTENT'), findsOneWidget);
    });

    testWidgets('a tablet gets a rail and still no results panel',
        (tester) async {
      await pumpAt(tester, const Size(800, 1000));
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('RESULTS'), findsNothing);
    });

    testWidgets('a desktop shows the inputs and the answer at once',
        (tester) async {
      await pumpAt(tester, const Size(1440, 900));
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('RESULTS'), findsOneWidget);
      expect(find.text('CONTENT'), findsOneWidget,
          reason: 'that they share a screen is the whole point');
    });

    testWidgets('selecting a destination swaps the content', (tester) async {
      var selected = 0;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => MaterialApp(
            home: AdaptiveScaffold(
              title: 'Slow Burn',
              selectedIndex: selected,
              onSelect: (i) => setState(() => selected = i),
              results: const Text('RESULTS'),
              destinations: [
                Destination(
                  label: 'Household',
                  icon: Icons.people_outline,
                  selectedIcon: Icons.people,
                  build: () => const Text('CONTENT'),
                ),
                Destination(
                  label: 'Income',
                  icon: Icons.work_outline,
                  selectedIcon: Icons.work,
                  build: () => const Text('OTHER'),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('CONTENT'), findsOneWidget);
      await tester.tap(find.text('Income').last);
      await tester.pumpAndSettle();
      expect(find.text('OTHER'), findsOneWidget);
    });
  });
}
