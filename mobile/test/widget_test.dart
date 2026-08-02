import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/main.dart';

void main() {
  testWidgets('shows onboarding when Echo is not configured', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const EchoApp());
    await tester.pumpAndSettle();

    expect(find.text('Connect to your second brain'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('API Key'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });
}
