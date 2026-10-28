import 'package:echo_app/widgets/expandable_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, String text) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: ExpandableText(text, key: const Key('text'), maxLines: 2),
          ),
        ),
      ));

  int? shownLines(WidgetTester tester) => tester
      .widget<Text>(find.descendant(of: find.byKey(const Key('text')), matching: find.byType(Text)))
      .maxLines;

  testWidgets('a text that does not fit opens in full on a tap, and closes again',
      (tester) async {
    await pump(tester, 'Domani a Milano piove dalle 15 alle 21, porta l’ombrello. ' * 6);
    expect(shownLines(tester), 2);

    await tester.tap(find.byKey(const Key('text')));
    await tester.pump();
    expect(shownLines(tester), isNull);

    await tester.tap(find.byKey(const Key('text')));
    await tester.pump();
    expect(shownLines(tester), 2);
  });

  testWidgets('a text that fits is shown as it is, with nothing to tap', (tester) async {
    await pump(tester, 'Sole, 14°.');

    expect(
      find.descendant(of: find.byKey(const Key('text')), matching: find.byType(GestureDetector)),
      findsNothing,
    );
  });
}
