import 'package:echo_app/screens/settings/notification_settings_screen.dart';
import 'package:echo_app/services/app/notification_scheduler.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('switches are saved and reschedule', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var changes = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: NotificationSettingsScreen(
        preferences: preferences,
        onChanged: () => changes++,
      ),
    ));

    Switch at(String key) => tester.widget<Switch>(find.byKey(Key(key)));
    expect(at(NotificationPreferences.briefingsKey).value, isTrue);
    expect(at(NotificationPreferences.promisesKey).value, isTrue);
    expect(at(NotificationPreferences.eveningKey).value, isFalse);

    await tester.tap(find.byKey(const Key(NotificationPreferences.eveningKey)));
    await tester.pumpAndSettle();

    expect(preferences.getBool(NotificationPreferences.eveningKey), isTrue);
    expect(at(NotificationPreferences.eveningKey).value, isTrue);
    expect(changes, 1);
  });
}
