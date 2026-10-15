import 'package:echo_app/models/device_command.dart';
import 'package:echo_app/screens/settings/automations_settings_screen.dart';
import 'package:echo_app/screens/settings/phone_apps_screen.dart';
import 'package:echo_app/services/api/device_api.dart';
import 'package:echo_app/services/phone/phone_actions.dart';
import 'package:echo_app/services/phone/phone_calendar.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late _Calendar calendar;
  late _Server server;
  late PhoneActionsService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    calendar = _Calendar();
    server = _Server();
    service = PhoneActionsService(
      calendar: calendar,
      choices: PhoneAppChoices(await SharedPreferences.getInstance()),
      commands: server,
      server: server,
    );
  });

  Future<void> pump(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light, home: screen));
    await tester.pumpAndSettle();
  }

  Switch switchOf(WidgetTester tester, PhoneApp app) =>
      tester.widget<Switch>(find.byKey(Key('phone-app-${app.name}')));

  testWidgets('a switch asks iOS, then the app is on and the server knows', (tester) async {
    await pump(tester, PhoneAppsScreen(phoneActions: service));
    expect(switchOf(tester, PhoneApp.reminders).value, isFalse);

    await tester.tap(find.byKey(const Key('phone-app-reminders')));
    await tester.pumpAndSettle();

    expect(calendar.requested, [PhoneApp.reminders]);
    expect(switchOf(tester, PhoneApp.reminders).value, isTrue);
    expect(server.reports.last, (reminders: true, calendar: false));
  });

  testWidgets('an app iOS refused points to iOS Settings', (tester) async {
    calendar.accessOf[PhoneApp.calendar] = PhoneAccess.denied;
    var opened = 0;
    await pump(
      tester,
      PhoneAppsScreen(phoneActions: service, openSettings: () async => opened++),
    );

    expect(find.byKey(const Key('phone-apps-denied')), findsOneWidget);
    await tester.tap(find.text('Open iOS Settings'));
    expect(opened, 1);
  });

  testWidgets('Automations leads to it', (tester) async {
    await pump(tester, AutomationsSettingsScreen(phoneActions: service));
    await tester.tap(find.text('On this iPhone'));
    await tester.pumpAndSettle();

    expect(find.byType(PhoneAppsScreen), findsOneWidget);
  });
}

final class _Calendar implements PhoneCalendar {
  final accessOf = <PhoneApp, PhoneAccess>{};
  final requested = <PhoneApp>[];

  @override
  Future<PhoneAccess> access(PhoneApp app) async => accessOf[app] ?? PhoneAccess.notAsked;

  @override
  Future<bool> requestAccess(PhoneApp app) async {
    requested.add(app);
    accessOf[app] = PhoneAccess.granted;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _Server implements DeviceCommandsApi, PhoneAppsApi {
  final reports = <({bool reminders, bool calendar})>[];

  @override
  Future<void> reportPhoneApps({required bool reminders, required bool calendar}) async =>
      reports.add((reminders: reminders, calendar: calendar));

  @override
  Future<void> sendCommandResult(String commandId, Map<String, Object?> result) async {}

  @override
  Future<List<DeviceCommand>> getDeviceCommands({Duration wait = Duration.zero}) async => [];
}
