import 'package:echo_app/screens/settings/instructions_screen.dart';
import 'package:echo_app/services/app/spoken_language.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakeInstructionsApi implements InstructionsApi {
  final saved = <String?>[];

  @override
  Future<AccountInfo> setInstructions(String? instructions) async {
    saved.add(instructions);
    return AccountInfo(email: 'erik@x.io', language: 'it', instructions: instructions);
  }
}

Future<AccountInfo?> _open(WidgetTester tester, InstructionsApi api, {String? initial}) async {
  AccountInfo? result;
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light,
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          result = await Navigator.push<AccountInfo>(
            context,
            MaterialPageRoute(builder: (_) => InstructionsScreen(api: api, initial: initial)),
          );
        },
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('saves what was written, trimmed, and goes back with it', (tester) async {
    final api = _FakeInstructionsApi();
    AccountInfo? result;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await Navigator.push<AccountInfo>(
              context,
              MaterialPageRoute(builder: (_) => InstructionsScreen(api: api)),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('instructions-field')), '  Keep it short.  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(api.saved, ['Keep it short.']);
    expect(result?.instructions, 'Keep it short.');
  });

  testWidgets('an example adds its line; emptying clears them', (tester) async {
    final api = _FakeInstructionsApi();
    await _open(tester, api, initial: 'Call me Erik.');

    expect(find.text('Call me Erik.'), findsOneWidget);
    await tester.tap(find.text('Keep answers short'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byKey(const Key('instructions-field'))).controller!.text,
      'Call me Erik.\nKeep answers short.',
    );

    await tester.enterText(find.byKey(const Key('instructions-field')), '   ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.saved, [null]);
  });
}
