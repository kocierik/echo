import 'package:echo_app/main.dart';
import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/models/session_state.dart';
import 'package:echo_app/screens/home_screen.dart';
import 'package:echo_app/screens/navigation.dart';
import 'package:echo_app/screens/person_screen.dart';
import 'package:echo_app/screens/tasks_screen.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/services/app/app_controller.dart';
import 'package:echo_app/services/app/spoken_language.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/tasks_request_listener.dart';
import 'package:echo_app/widgets/account_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Some tab animates for ever, so pumpAndSettle never returns: a second of frames instead.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late AppController appController;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    appController = AppController(
      initialDevice: const DeviceStatus(connectionState: DeviceConnectionState.listening),
      deviceStates: const Stream.empty(),
      initialSession: const SessionState(SessionStatus.loggedIn),
      sessionStates: const Stream.empty(),
      preferences: SharedPreferencesAppPreferences(preferences),
    );
    await appController.initialize();
  });

  tearDown(() {
    TabNavigators.keys = const [];
    appController.dispose();
  });

  Future<void> pumpShell(WidgetTester tester, {AccountInfo? account}) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: MainShell(
        appController: appController,
        apiServiceFactory: () => _AccountApi(account ?? const AccountInfo(email: null, language: 'en')),
      ),
    ));
    await settle(tester);
  }

  testWidgets('a person request opens the person in Library, with the bar', (tester) async {
    await pumpShell(tester);
    appController.pendingPersonId.value = 'person-1';
    await settle(tester);

    expect(appController.value.selectedTab, AppController.libraryTab);
    expect(find.byType(PersonScreen), findsOneWidget);
    expect(find.byKey(const Key('echo-nav-2')), findsOneWidget);
    expect(TabNavigators.keys[AppController.libraryTab].currentState!.canPop(), isTrue);
  });

  testWidgets('a tasks request opens the Tasks page in Library, with the bar', (tester) async {
    await pumpShell(tester);
    appController.requestOpenTasks();
    await settle(tester);

    expect(appController.value.selectedTab, AppController.libraryTab);
    expect(find.byType(TasksPage), findsOneWidget);
    expect(find.byKey(const Key('echo-nav-2')), findsOneWidget);
    expect(TabNavigators.keys[AppController.todayTab].currentState!.canPop(), isFalse);
  });

  testWidgets('a session request lands on Ask\'s first page, not under a page left open',
      (tester) async {
    await pumpShell(tester);
    final ask = TabNavigators.keys[AppController.askTab].currentState!;
    ask.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('History'))));
    await appController.setSelectedTab(AppController.askTab);
    await settle(tester);
    expect(find.text('History'), findsOneWidget);

    appController.handleNotificationPayload('voice:session-1');
    await settle(tester);

    expect(find.text('History'), findsNothing);
    expect(ask.canPop(), isFalse);
    expect(appController.value.selectedTab, AppController.askTab);
  });

  testWidgets('a routines notification lands on Ask, not under History', (tester) async {
    await pumpShell(tester);
    final ask = TabNavigators.keys[AppController.askTab].currentState!;
    ask.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('History'))));
    await appController.setSelectedTab(AppController.askTab);
    await settle(tester);

    appController.handleNotificationPayload('routines:run-1');
    await settle(tester);

    expect(find.text('History'), findsNothing);
    expect(ask.canPop(), isFalse);
  });

  testWidgets('a person notification closes the account sheet over the tabs', (tester) async {
    await pumpShell(tester);
    Navigator.of(tester.element(find.byType(HomeScreen)), rootNavigator: true).push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Sheet'))));
    await settle(tester);
    expect(find.text('Sheet'), findsOneWidget);

    appController.handleNotificationPayload('person:person-1');
    await settle(tester);

    expect(find.text('Sheet'), findsNothing);
    expect(find.byType(PersonScreen), findsOneWidget);
  });

  testWidgets('holding Ask to dictate shows Ask, not History', (tester) async {
    await pumpShell(tester);
    final ask = TabNavigators.keys[AppController.askTab].currentState!;
    ask.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('History'))));
    await appController.setSelectedTab(AppController.askTab);
    await settle(tester);

    appController.setAskDictation(true);
    await settle(tester);

    expect(find.text('History'), findsNothing);
    expect(ask.canPop(), isFalse);
  });

  testWidgets('a second tasks request does not stack Tasks pages', (tester) async {
    await pumpShell(tester);
    appController.requestOpenTasks();
    await settle(tester);
    appController.requestOpenTasks();
    await settle(tester);

    final library = TabNavigators.keys[AppController.libraryTab].currentState!;
    library.pop();
    await settle(tester);
    expect(library.canPop(), isFalse);
  });

  testWidgets('a tasks request made before the listener existed still opens', (tester) async {
    final requests = ValueNotifier<int>(1);
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: TasksRequestListener(
          requests: requests, onOpen: () => opened++, child: const SizedBox()),
    ));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('a question for Ask also lands on its first page', (tester) async {
    await pumpShell(tester);
    final ask = TabNavigators.keys[AppController.askTab].currentState!;
    ask.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('A saved item'))));
    await settle(tester);

    appController.requestAsk('What did Marco say?');
    await settle(tester);

    expect(ask.canPop(), isFalse);
  });

  testWidgets('Today has the person icon for account and settings', (tester) async {
    await pumpShell(tester, account: const AccountInfo(email: 'a@x.io', language: 'en', name: 'Erik'));

    expect(
      find.descendant(of: find.byType(HomeScreen), matching: find.byType(AccountButton)),
      findsOneWidget,
    );
  });
}

final class _AccountApi extends ApiService {
  _AccountApi(this.account);

  final AccountInfo account;

  @override
  Future<AccountInfo> me() async => account;
}
