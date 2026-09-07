import 'package:burn_engine/burn_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slow_burn/widgets/fields.dart';

Future<void> pumpField(WidgetTester tester, Widget field) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Padding(
        padding: const EdgeInsets.all(24),
        child: field,
      ))),
    );

TextSelection selectionOf(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.selection;

void main() {
  group('clicking into a field selects what is in it', () {
    testWidgets('so typing replaces an amount rather than joining it',
        (tester) async {
      // Landing a cursor inside "1500" and typing "2" gives 15002, which is
      // nobody's intention.
      var latest = Money.zero;
      await pumpField(
        tester,
        MoneyField(
          label: 'Amount',
          initial: Money.dollars(1500),
          onChanged: (v) => latest = v,
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(selectionOf(tester).baseOffset, 0);
      expect(selectionOf(tester).extentOffset, '1500.00'.length);

      await tester.enterText(find.byType(TextField), '2000');
      expect(latest, Money.dollars(2000));
    });

    testWidgets('and a percentage the same way', (tester) async {
      await pumpField(
        tester,
        PercentField(label: 'Rate', initial: 0.045, onChanged: (_) {}),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(selectionOf(tester).extentOffset, '4.5'.length);
    });

    testWidgets('and a name', (tester) async {
      await pumpField(
        tester,
        LabelledTextField(
          label: 'Name',
          initial: 'Acme',
          onChanged: (_) {},
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(selectionOf(tester).extentOffset, 'Acme'.length);
    });

    testWidgets('an empty field selects nothing and is not upset by it',
        (tester) async {
      await pumpField(
        tester,
        MoneyField(label: 'Amount', onChanged: (_) {}),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(selectionOf(tester).extentOffset, 0);
    });
  });
}
