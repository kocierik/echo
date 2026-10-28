import 'package:echo_app/screens/settings/spoken_answers_screen.dart';
import 'package:echo_app/services/app/spoken_answers_store.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the three choices; a tap keeps it; Try it speaks', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SpokenAnswersStore(await SharedPreferences.getInstance());
    var tries = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: SpokenAnswersScreen(store: store, onTry: () async => tries++),
    ));

    for (final label in ['Off', 'Headphones', 'Always']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('Headphones'));
    await tester.pumpAndSettle();
    expect(store.value, SpokenAnswers.headphones);

    await tester.tap(find.byKey(const Key('spoken-answers-try')));
    await tester.pumpAndSettle();
    expect(tries, 1);
  });
}
