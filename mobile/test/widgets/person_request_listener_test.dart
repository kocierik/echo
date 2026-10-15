import 'package:echo_app/screens/person_screen.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/person_request_listener.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

void main() {
  testWidgets('a briefing tap opens the person once', (tester) async {
    final request = ValueNotifier<String?>(null);
    addTearDown(request.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: PersonRequestListener(
        request: request,
        api: FakeMemoryApi(),
        child: const Scaffold(body: Text('shell')),
      ),
    ));

    request.value = 'p-1';
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(PersonScreen), findsOneWidget);
    expect(tester.widget<PersonScreen>(find.byType(PersonScreen)).personId, 'p-1');
    expect(request.value, isNull);
  });
}
