import 'dart:async';

import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/models/today_insights.dart';
import 'package:echo_app/screens/home_screen.dart';
import 'package:echo_app/services/api/actions_api.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

void main() {
  // A Wednesday evening
  final now = DateTime(2026, 10, 14, 18);
  const listening = DeviceStatus(connectionState: DeviceConnectionState.listening);
  const muted = DeviceStatus(connectionState: DeviceConnectionState.muted);
  const connecting = DeviceStatus(connectionState: DeviceConnectionState.connecting);
  const offline = DeviceStatus(connectionState: DeviceConnectionState.offline);
  const unpaired = DeviceStatus(connectionState: DeviceConnectionState.unpaired);
  const bluetoothOff = DeviceStatus(connectionState: DeviceConnectionState.bluetoothOff);

  final calls = <String>[];

  Future<void> pumpToday(
    WidgetTester tester, {
    FakeTodayApi? api,
    DeviceStatus status = listening,
    Future<void> Function()? onReconnect,
    Stream<Object?>? uploads,
    ThemeData? theme,
    Size size = const Size(375, 812),
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      theme: theme ?? AppTheme.light,
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: HomeScreen(
            api: api ?? FakeTodayApi(),
            deviceStatus: status,
            onReconnect: onReconnect,
            onPair: () => calls.add('pair'),
            onOpenMemories: () => calls.add('memories'),
            onOpenTasks: () => calls.add('tasks'),
            onOpenChat: (id) => calls.add('chat $id'),
            workingPollInterval: const Duration(seconds: 1),
            openConversation: (context, id) async => calls.add('open $id'),
            segmentUploadedStream: uploads,
            manageAppsBuilder: (_) => const Scaffold(body: Text('Manage apps page')),
            addAppBuilder: (_) => const Scaffold(body: Text('Add app page')),
            clock: () => now,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  setUp(calls.clear);

  group('device', () {
    testWidgets('every state fits light and dark viewports', (tester) async {
      for (final theme in [AppTheme.light, AppTheme.dark]) {
        for (final viewport in const [
          (size: Size(375, 812), textScale: 1.0),
          (size: Size(320, 640), textScale: 1.3),
        ]) {
          for (final status in [listening, muted, connecting, offline, unpaired, bluetoothOff]) {
            await pumpToday(
              tester,
              status: status,
              theme: theme,
              size: viewport.size,
              textScale: viewport.textScale,
            );
            expect(tester.takeException(), isNull);
          }
        }
      }
    });

    testWidgets('a working Echo takes no room: the pill tells its state', (tester) async {
      for (final status in [listening, muted, connecting]) {
        await pumpToday(tester, status: status);
        expect(find.byKey(const Key('device-problem')), findsNothing);
      }
    });

    testWidgets('offline reconnects, and says when it cannot', (tester) async {
      var reconnects = 0;
      await pumpToday(
        tester,
        status: offline,
        onReconnect: () async {
          reconnects++;
          if (reconnects == 2) throw StateError('no radio');
        },
      );

      expect(find.text('Echo is offline'), findsOneWidget);
      await tester.tap(find.text('Reconnect Echo'));
      await tester.pump();
      expect(reconnects, 1);

      await tester.tap(find.text('Reconnect Echo'));
      await tester.pump();
      expect(find.text('Echo could not start reconnecting.'), findsOneWidget);
    });

    testWidgets('without a paired Echo it offers pairing', (tester) async {
      await pumpToday(tester, status: unpaired);

      expect(find.text('No Echo paired'), findsOneWidget);
      await tester.tap(find.text('Pair Echo'));
      await tester.pump();

      expect(calls, ['pair']);
    });

    testWidgets('Bluetooth off says where to turn it on', (tester) async {
      await pumpToday(tester, status: bluetoothOff);

      expect(find.text('Bluetooth is off'), findsOneWidget);
      expect(find.byKey(const Key('device-action')), findsNothing);
    });
  });

  group('your day', () {
    FakeTodayApi withConversations() => FakeTodayApi(conversations: [
          card('live', startedAt: DateTime(2026, 10, 14, 17, 50), title: null, isOpen: true,
              people: const [], taskCount: 0, duration: const Duration(minutes: 10)),
          card('lunch', startedAt: DateTime(2026, 10, 14, 12, 30),
              duration: const Duration(minutes: 47), people: const ['Ada', 'Marco']),
          card('standup', startedAt: DateTime(2026, 10, 14, 9), title: 'Standup',
              summary: null, duration: const Duration(minutes: 8), people: const ['Luca'],
              taskCount: 0),
          card('yesterday', startedAt: DateTime(2026, 10, 13, 20), title: 'Dinner plans'),
        ]);

    testWidgets("puts today's conversations on a timeline, ending with now",
        (tester) async {
      await pumpToday(tester, api: withConversations());
      await tester.pumpAndSettle();

      expect(find.text('3 conversations, 1 h 5 min'), findsOneWidget);
      expect(find.text('With Ada, Marco, Luca'), findsOneWidget);
      expect(find.text('Dinner plans'), findsNothing);
      expect(find.text('09:00'), findsOneWidget);
      expect(find.text('12:30'), findsOneWidget);
      expect(find.text('Recording'), findsOneWidget);
      // Oldest first, like the day went
      expect(
        tester.getTopLeft(find.text('Standup')).dy,
        lessThan(tester.getTopLeft(find.text('Lunch with Ada')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Lunch with Ada')).dy,
        lessThan(tester.getTopLeft(find.text('Recording')).dy),
      );

      await tester.tap(find.text('Lunch with Ada'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('day-now')));
      await tester.tap(find.byKey(const Key('day-now')));
      await tester.pumpAndSettle();
      expect(calls, ['open lunch', 'open live']);

      await tester.ensureVisible(find.byKey(const Key('recap-see-all')));
      await tester.tap(find.byKey(const Key('recap-see-all')));
      expect(calls.last, 'memories');
    });

    testWidgets('a muted Echo shows the open conversation as in progress',
        (tester) async {
      await pumpToday(tester, api: withConversations(), status: muted);
      await tester.pumpAndSettle();

      expect(find.text('Recording'), findsNothing);
      expect(find.text('In progress'), findsOneWidget);
    });

    testWidgets('the latest four, and how many came earlier', (tester) async {
      await pumpToday(
        tester,
        api: FakeTodayApi(conversations: [
          for (var hour = 14; hour >= 8; hour--)
            card('c$hour', startedAt: DateTime(2026, 10, 14, hour), title: 'At $hour'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('3 earlier today'), findsOneWidget);
      expect(find.text('At 8'), findsNothing);
      expect(find.text('At 11'), findsOneWidget);
      expect(find.text('At 14'), findsOneWidget);
    });

    testWidgets('empty and error states', (tester) async {
      await pumpToday(tester);
      await tester.pumpAndSettle();
      expect(find.text('No conversations yet today.'), findsOneWidget);

      final api = withConversations()..listError = serverError('Offline');
      await tester.pumpWidget(const SizedBox());
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();
      expect(find.text('Offline'), findsWidgets);

      api.listError = null;
      await tester.ensureVisible(find.byKey(const Key('recap-retry')));
      await tester.tap(find.byKey(const Key('recap-retry')));
      await tester.pumpAndSettle();
      expect(find.text('Standup'), findsOneWidget);
    });

    testWidgets('new speech refreshes conversations and tasks', (tester) async {
      final uploads = StreamController<Object?>();
      addTearDown(uploads.close);
      final api = FakeTodayApi();
      await pumpToday(tester, api: api, uploads: uploads.stream);
      await tester.pumpAndSettle();
      final before = api.calls.length;

      uploads.add(null);
      await tester.pumpAndSettle();

      expect(api.calls.skip(before), unorderedEquals(['list 30 0', 'tasks false']));
    });
  });

  group('to do today', () {
    FakeTodayApi withTasks() => FakeTodayApi(openTasks: [
          task('late', 'Pay the bill', due: DateTime(2026, 10, 12)),
          task('today', 'Call Ada', due: DateTime(2026, 10, 14)),
          task('later', 'Book the trip', due: DateTime(2026, 10, 30),
              createdAt: DateTime(2026, 10, 1)),
          task('fresh', 'Buy a gift', createdAt: DateTime(2026, 10, 14, 11),
              source: '[Tu] Devo comprare un regalo.'),
          task('old', 'Old idea', createdAt: DateTime(2026, 10, 1)),
        ]);

    testWidgets('shows what is due and what was created today, without quotes',
        (tester) async {
      await pumpToday(tester, api: withTasks());
      await tester.pumpAndSettle();

      expect(find.text('Pay the bill'), findsOneWidget);
      expect(find.text('Overdue · Oct 12'), findsOneWidget);
      expect(find.text('Call Ada'), findsOneWidget);
      expect(find.text('Buy a gift'), findsOneWidget);
      expect(find.text('“Devo comprare un regalo.”'), findsNothing);
      expect(find.text('Book the trip'), findsNothing);
      expect(find.text('Old idea'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Pay the bill')).dy,
        lessThan(tester.getTopLeft(find.text('Buy a gift')).dy),
      );
    });

    testWidgets('a promise due today comes first; three at most', (tester) async {
      final api = withTasks()
        ..openTasks.addAll([
          promise('budget', 'Send both budget options', to: 'Marco',
              due: DateTime(2026, 10, 14)),
          promise('later', 'Lend Ada the book', due: DateTime(2026, 10, 20)),
        ]);
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();

      expect(find.text('Promised to Marco'), findsOneWidget);
      expect(find.text('Lend Ada the book'), findsNothing);
      expect(find.text('Buy a gift'), findsNothing);
      expect(find.text('1 more in Tasks'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Send both budget options')).dy,
        lessThan(tester.getTopLeft(find.text('Pay the bill')).dy),
      );
    });

    testWidgets('a task is completed or dropped in place', (tester) async {
      final api = withTasks();
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('task-toggle-today')));
      await tester.tap(find.byKey(const Key('task-toggle-today')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('done today true'));

      await tester.ensureVisible(find.byKey(const Key('task-menu-fresh')));
      await tester.tap(find.byKey(const Key('task-menu-fresh')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-dismiss-fresh')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('delete entity fresh'));
      expect(find.text('Buy a gift'), findsNothing);
    });

    testWidgets('nothing due, and See all', (tester) async {
      await pumpToday(tester);
      await tester.pumpAndSettle();
      expect(find.text('Nothing due today.'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('tasks-see-all')));
      await tester.tap(find.byKey(const Key('tasks-see-all')));
      expect(calls, ['tasks']);
    });
  });

  group('needs you', () {
    const voice = PendingAction(
      id: 'a1',
      summary: 'Send the budget to Marco',
      status: 'pending',
      app: 'Gmail',
      source: 'voice',
    );

    testWidgets('is hidden when nothing waits', (tester) async {
      await pumpToday(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('needs-you')), findsNothing);
    });

    testWidgets('confirms a voice request in place', (tester) async {
      final api = FakeTodayApi(pending: [voice])
        ..confirmResult = const ConfirmResult(status: 'executed', message: 'Email sent.');
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();

      expect(find.text('Needs you'), findsOneWidget);
      expect(find.text('Gmail, asked by voice'), findsOneWidget);
      expect(find.text('Send the budget to Marco'), findsOneWidget);
      await tester.tap(find.byKey(const Key('action-confirm-a1')));
      await tester.pumpAndSettle();

      expect(api.calls, contains('confirm a1'));
      expect(find.text('Email sent.'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.byKey(const Key('action-confirm-a1')), findsNothing);
    });

    testWidgets('cancels, and reports a failed confirm', (tester) async {
      final api = FakeTodayApi(pending: [voice])..confirmError = serverError('Expired');
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('action-confirm-a1')));
      await tester.pumpAndSettle();
      expect(find.text('Expired'), findsOneWidget);

      await tester.tap(find.byKey(const Key('action-cancel-a1')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('cancel a1'));
    });
  });

  group('echo can act in', () {
    testWidgets('shows the connected apps and opens Manage and Add',
        (tester) async {
      final api = _ToolkitsTodayApi([
        const Toolkit(slug: 'gmail', name: 'Gmail', description: '', connected: true),
        const Toolkit(slug: 'slack', name: 'Slack', description: '', connected: false),
      ]);
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Gmail, on'), findsOneWidget);
      expect(find.bySemanticsLabel('Slack, on'), findsNothing);
      expect(find.text('1 app on'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('acts-in-manage')));
      await tester.tap(find.byKey(const Key('acts-in-manage')));
      await tester.pumpAndSettle();
      expect(find.text('Manage apps page'), findsOneWidget);
      Navigator.of(tester.element(find.text('Manage apps page'))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('acts-in-add')));
      await tester.pumpAndSettle();
      expect(find.text('Add app page'), findsOneWidget);
    });

    testWidgets('is there with no app yet, saying what it is for', (tester) async {
      await pumpToday(tester, api: _ToolkitsTodayApi(const [], fails: true));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('acts-in')), findsOneWidget);
      expect(
        find.text('Connect an app and Echo can send, add and remind for you.'),
        findsOneWidget,
      );
    });
  });

  testWidgets('a request being answered shows until its answer arrives', (tester) async {
    final api = FakeTodayApi()
      ..working = [
        WorkingItem(
          key: 'photo:p1',
          kind: 'photo',
          text: 'Che pianta è?',
          since: DateTime(2026, 10, 14, 17),
          sessionId: 's1',
        ),
      ];
    await pumpToday(tester, api: api);
    await tester.pump();

    expect(find.text('📷 Taking a photo: Che pianta è?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('working-photo:p1')));
    expect(calls.last, 'chat s1');

    api.working = [];
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(const Key('working-section')), findsNothing);
  });

  testWidgets('the daily and weekly summaries live in Memories now', (tester) async {
    await pumpToday(
      tester,
      api: FakeTodayApi(
        digest: DailySummary(date: DateTime(2026, 10, 13), summary: 'Met Ada about Atlas.'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Met Ada about Atlas.'), findsNothing);
    expect(find.byKey(const Key('weekly-summary')), findsNothing);
  });

  testWidgets('a full Today fits 320 wide at 1.3 text scale', (tester) async {
    final api = _ToolkitsTodayApi(
      [
        for (final slug in ['gmail', 'slack', 'notion', 'github', 'todoist'])
          Toolkit(slug: slug, name: slug, description: '', connected: true),
      ],
      conversations: [
        card('c1', startedAt: DateTime(2026, 10, 14, 12),
            title: 'A long conversation title about many things at once',
            people: const ['Alessandro', 'Margherita', 'Bartolomeo', 'Ada']),
        card('c2', startedAt: DateTime(2026, 10, 14, 17, 40), isOpen: true),
      ],
      openTasks: [
        task('t1', 'A rather long task name that needs to wrap on a small screen',
            due: DateTime(2026, 10, 10), source: '[Tu] Una frase lunga da cui nasce il task.'),
        promise('p1', 'A long promise to someone with a long name', to: 'Bartolomeo Alessandrini',
            due: DateTime(2026, 10, 14)),
      ],
      pending: const [
        PendingAction(id: 'a1', summary: 'Send a long email to many people', status: 'pending',
            app: 'Google Calendar', source: 'voice'),
      ],
    );
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      await pumpToday(tester, api: api, theme: theme, size: const Size(320, 640), textScale: 1.3);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });
}

/// Today's api with Composio's apps (or failing, like without Composio).
final class _ToolkitsTodayApi extends FakeTodayApi implements ToolkitsApi {
  _ToolkitsTodayApi(
    this.toolkits, {
    this.fails = false,
    super.conversations,
    super.openTasks,
    super.pending,
  });

  final List<Toolkit> toolkits;
  final bool fails;

  @override
  Future<List<Toolkit>> getToolkits({String? query}) async {
    if (fails) throw serverError('Composio is not configured');
    return toolkits;
  }
}
