import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/screens/integrations_screen.dart';
import 'package:echo_app/services/api/api_exception.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Toolkit _toolkit(String slug, String name, {bool connected = false}) => Toolkit(
      slug: slug,
      name: name,
      description: '$name description',
      connected: connected,
    );

final class _FakeApi extends ApiService {
  _FakeApi();

  List<Toolkit> initial = [
    _toolkit('gmail', 'Gmail', connected: true),
    _toolkit('googlecalendar', 'Google Calendar'),
    _toolkit('slack', 'Slack'),
    _toolkit('telegram', 'Telegram'),
    _toolkit('todoist', 'Todoist'),
    _toolkit('notion', 'Notion'),
  ];
  List<Toolkit> searchResults = [_toolkit('asana', 'Asana')];
  ApiException? error;
  Exception? otherError;
  final queries = <String?>[];
  final connected = <String>[];
  final disconnected = <String>[];

  @override
  Future<List<Toolkit>> getToolkits({String? query}) async {
    queries.add(query);
    if (error != null) throw error!;
    if (otherError != null) throw otherError!;
    return (query == null || query.isEmpty) ? initial : searchResults;
  }

  @override
  Future<String> connectToolkit(String slug) async {
    connected.add(slug);
    return 'https://auth.test/$slug';
  }

  @override
  Future<void> disconnectToolkit(String slug) async {
    disconnected.add(slug);
  }

  @override
  void dispose() {}
}

void main() {
  late _FakeApi api;
  late List<Uri> launched;

  setUp(() {
    api = _FakeApi();
    launched = [];
  });

  Future<void> pumpScreen(WidgetTester tester, {Widget? activity}) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: IntegrationsScreen(
        api: api,
        activity: activity,
        launcher: (uri) async {
          launched.add(uri);
          return true;
        },
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the initial toolkits with Connected or Connect',
      (tester) async {
    await pumpScreen(tester);

    for (final name in [
      'Gmail',
      'Google Calendar',
      'Slack',
      'Telegram',
      'Todoist',
      'Notion',
    ]) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.text('Gmail description'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Connect'), findsNWidgets(5));
    expect(find.text('Search other apps'), findsOneWidget);
  });

  testWidgets('Activity, when given, comes before the apps', (tester) async {
    await pumpScreen(tester, activity: const Text('Activity'));
    expect(tester.getTopLeft(find.text('Activity')).dy,
        lessThan(tester.getTopLeft(find.text('Gmail')).dy));
  });

  testWidgets('Connect opens the returned URL and reloads on resume',
      (tester) async {
    await pumpScreen(tester);
    final initialLoads = api.queries.length;

    await tester.tap(find.widgetWithText(FilledButton, 'Connect').first);
    await tester.pumpAndSettle();

    expect(api.connected, ['googlecalendar']);
    expect(launched.single.toString(), 'https://auth.test/googlecalendar');
    // Reloaded after the launcher returned.
    expect(api.queries.length, initialLoads + 1);

    api.initial = [
      _toolkit('googlecalendar', 'Google Calendar', connected: true),
    ];
    _leaveAndReturn(tester);
    await tester.pumpAndSettle();

    expect(api.queries.length, initialLoads + 2);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
  });

  testWidgets('Disconnect asks for confirmation first', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    expect(
      find.text('Disconnect Gmail? Echo will no longer be able to use it.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.disconnected, isEmpty);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
    await tester.pumpAndSettle();

    expect(api.disconnected, ['gmail']);
  });

  testWidgets('search shows other toolkits', (tester) async {
    await pumpScreen(tester);

    await tester.enterText(find.byType(TextField), 'asa');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(api.queries.last, 'asa');
    expect(find.text('Asana'), findsOneWidget);
    expect(find.text('Gmail'), findsNothing);
  });

  testWidgets('unavailable shows the setup message', (tester) async {
    api.error = const ApiException(
      statusCode: 503,
      code: 'unavailable',
      message: 'Composio is not configured',
      retryable: true,
    );
    await pumpScreen(tester);

    expect(
      find.text(
        "Integrations aren't set up on the server yet. Add COMPOSIO_API_KEY "
        'to the backend .env and restart it.',
      ),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('another 503 shows the error and Retry, not the setup text',
      (tester) async {
    api.error = const ApiException(
      statusCode: 503,
      code: 'unavailable',
      message: 'Service Unavailable',
      retryable: true,
    );
    await pumpScreen(tester);

    expect(find.textContaining("aren't set up"), findsNothing);
    expect(find.text('Service Unavailable'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('other errors show the message and Retry', (tester) async {
    api.error = const ApiException(
      statusCode: 500,
      code: 'server',
      message: 'Server exploded',
      retryable: true,
    );
    await pumpScreen(tester);

    expect(find.text('Server exploded'), findsOneWidget);

    api.error = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Gmail'), findsOneWidget);
  });

  void resume(WidgetTester tester) {
    _leaveAndReturn(tester);
  }

  testWidgets('a failed reload on resume keeps the list and shows a SnackBar',
      (tester) async {
    await pumpScreen(tester);
    final loads = api.queries.length;

    api.error = const ApiException(
      statusCode: 500,
      code: 'server',
      message: 'Server exploded',
      retryable: true,
    );
    resume(tester);
    await tester.pumpAndSettle();

    expect(api.queries.length, loads + 1);
    expect(find.text("Couldn't refresh the list."), findsOneWidget);
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Server exploded'), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a failed reload after Connect keeps the list', (tester) async {
    await pumpScreen(tester);

    api.otherError = Exception('socket closed');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect').first);
    await tester.pumpAndSettle();

    expect(api.connected, ['googlecalendar']);
    expect(find.text("Couldn't refresh the list."), findsOneWidget);
    expect(find.text('Google Calendar'), findsOneWidget);
    expect(find.text('Could not load integrations.'), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('an explicit load that fails still shows the error view',
      (tester) async {
    await pumpScreen(tester);

    api.error = const ApiException(
      statusCode: 500,
      code: 'server',
      message: 'Server exploded',
      retryable: true,
    );
    await tester.enterText(find.byType(TextField), 'asa');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('Server exploded'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text("Couldn't refresh the list."), findsNothing);
  });

  testWidgets('a failed silent reload over the error view keeps the error',
      (tester) async {
    api.error = const ApiException(
      statusCode: 500,
      code: 'server',
      message: 'Server exploded',
      retryable: true,
    );
    await pumpScreen(tester);

    resume(tester);
    await tester.pumpAndSettle();

    expect(find.text('Server exploded'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text("Couldn't refresh the list."), findsNothing);
  });
}

/// Leaves the app and comes back through every lifecycle state, as a device
/// does: AppLifecycleListener asserts on a jump such as paused -> resumed.
void _leaveAndReturn(WidgetTester tester) {
  for (final state in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}
