import 'dart:async';

import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/models/today_insights.dart';
import 'package:echo_app/screens/home_screen.dart';
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

  final calls = <String>[];

  Future<void> pumpToday(
    WidgetTester tester, {
    FakeTodayApi? api,
    DeviceStatus status = listening,
    Future<void> Function(bool)? setMuted,
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
            setMuted: setMuted ?? (_) async {},
            onReconnect: onReconnect,
            onPair: () => calls.add('pair'),
            onOpenMemories: () => calls.add('memories'),
            onOpenTasks: () => calls.add('tasks'),
            onOpenChat: (id) => calls.add('chat $id'),
            workingPollInterval: const Duration(seconds: 1),
            openConversation: (context, id) async => calls.add('open $id'),
            segmentUploadedStream: uploads,
            onMuteAcknowledged: () async {},
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
          for (final status in [listening, muted, connecting, offline, unpaired]) {
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

    testWidgets('mute waits for the device before changing state', (tester) async {
      final writes = <bool>[];
      Future<void> setMuted(bool value) async => writes.add(value);

      await pumpToday(tester, status: listening, setMuted: setMuted);
      await tester.tap(find.text('Mute microphone'));
      await tester.pump();

      expect(writes, [true]);
      expect(find.text('Listening'), findsOneWidget);
      expect(find.byKey(const Key('privacy-progress')), findsOneWidget);

      await pumpToday(tester, status: muted, setMuted: setMuted);

      expect(find.text('Microphone muted'), findsOneWidget);
      expect(find.text('Resume listening'), findsOneWidget);
      expect(find.byKey(const Key('privacy-progress')), findsNothing);
    });

    testWidgets('resume sends false', (tester) async {
      final writes = <bool>[];
      await pumpToday(tester, status: muted, setMuted: (value) async => writes.add(value));

      await tester.tap(find.text('Resume listening'));
      await tester.pump();

      expect(writes, [false]);
      await pumpToday(tester, status: listening);
    });

    testWidgets('a failed mute offers a retry', (tester) async {
      var attempts = 0;
      await pumpToday(
        tester,
        setMuted: (_) async {
          attempts++;
          if (attempts == 1) throw StateError('write failed');
        },
      );

      await tester.tap(find.text('Mute microphone'));
      await tester.pump();
      expect(find.text('Echo could not update the microphone.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('privacy-retry')));
      await tester.pump();
      expect(attempts, 2);
      await pumpToday(tester, status: muted);
    });

    testWidgets('no device change is confirmed after eight seconds', (tester) async {
      await pumpToday(tester, setMuted: (_) async {});

      await tester.tap(find.text('Mute microphone'));
      await tester.pump(const Duration(seconds: 9));

      expect(find.text('Echo did not confirm the microphone change.'), findsOneWidget);
    });

    testWidgets('connecting disables the action', (tester) async {
      final writes = <bool>[];
      await pumpToday(tester, status: connecting, setMuted: (v) async => writes.add(v));

      await tester.tap(find.byKey(const Key('privacy-action')));
      await tester.pump();

      expect(find.text('Connecting…'), findsOneWidget);
      expect(writes, isEmpty);
    });

    testWidgets('offline reconnects without pretending to listen', (tester) async {
      var reconnects = 0;
      await pumpToday(tester, status: offline, onReconnect: () async => reconnects++);

      await tester.tap(find.text('Reconnect Echo'));
      await tester.pump();

      expect(reconnects, 1);
      expect(find.text('Echo is offline'), findsOneWidget);
    });

    testWidgets('without a paired Echo it offers pairing', (tester) async {
      await pumpToday(tester, status: unpaired);

      expect(find.text('No Echo paired'), findsOneWidget);
      await tester.tap(find.text('Pair Echo'));
      await tester.pump();

      expect(calls, ['pair']);
    });
  });

  group('today so far', () {
    FakeTodayApi withConversations() => FakeTodayApi(conversations: [
          card('live', startedAt: DateTime(2026, 10, 14, 17, 50), title: null, isOpen: true,
              people: const [], taskCount: 0, duration: const Duration(minutes: 10)),
          card('lunch', startedAt: DateTime(2026, 10, 14, 12, 30),
              duration: const Duration(minutes: 47), people: const ['Ada', 'Marco']),
          card('standup', startedAt: DateTime(2026, 10, 14, 9), title: 'Standup',
              duration: const Duration(minutes: 8), people: const ['Luca']),
          card('yesterday', startedAt: DateTime(2026, 10, 13, 20), title: 'Dinner plans'),
        ]);

    testWidgets("recaps only today's conversations and opens one", (tester) async {
      await pumpToday(tester, api: withConversations());
      await tester.pumpAndSettle();

      expect(
        find.text('3 conversations · 1 h 5 min · with Ada, Marco, Luca'),
        findsOneWidget,
      );
      expect(find.text('Conversation in progress'), findsOneWidget);
      expect(find.text('Standup'), findsOneWidget);
      expect(find.text('Dinner plans'), findsNothing);

      await tester.tap(find.text('Lunch with Ada'));
      await tester.pumpAndSettle();
      expect(calls, ['open lunch']);

      await tester.tap(find.byKey(const Key('recap-see-all')));
      expect(calls.last, 'memories');
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

  group('tasks', () {
    FakeTodayApi withTasks() => FakeTodayApi(openTasks: [
          task('late', 'Pay the bill', due: DateTime(2026, 10, 12)),
          task('today', 'Call Ada', due: DateTime(2026, 10, 14)),
          task('later', 'Book the trip', due: DateTime(2026, 10, 30),
              createdAt: DateTime(2026, 10, 1)),
          task('fresh', 'Buy a gift', createdAt: DateTime(2026, 10, 14, 11),
              source: '[Tu] Devo comprare un regalo.'),
          task('old', 'Old idea', createdAt: DateTime(2026, 10, 1)),
        ]);

    testWidgets('shows what is due and what was created today', (tester) async {
      await pumpToday(tester, api: withTasks());
      await tester.pumpAndSettle();

      expect(find.text('Pay the bill'), findsOneWidget);
      expect(find.text('Overdue · Oct 12'), findsOneWidget);
      expect(find.text('Call Ada'), findsOneWidget);
      expect(find.text('Buy a gift'), findsOneWidget);
      expect(find.text('“Devo comprare un regalo.”'), findsOneWidget);
      expect(find.text('Book the trip'), findsNothing);
      expect(find.text('Old idea'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Pay the bill')).dy,
        lessThan(tester.getTopLeft(find.text('Buy a gift')).dy),
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

      expect(find.text('Gmail · Voice request'), findsOneWidget);
      expect(find.text('Send the budget to Marco'), findsOneWidget);
      await tester.tap(find.byKey(const Key('action-confirm-a1')));
      await tester.pumpAndSettle();

      expect(api.calls, contains('confirm a1'));
      expect(find.text('Email sent.'), findsOneWidget);
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

  group('daily summary', () {
    testWidgets("is labelled with its day", (tester) async {
      final api = FakeTodayApi(
        digest: DailySummary(date: DateTime(2026, 10, 13), summary: 'Met Ada about Atlas.'),
      );
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();

      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Met Ada about Atlas.'), findsOneWidget);
    });

    testWidgets('the weekly summary shows its week, expands to its highlights', (tester) async {
      await pumpToday(
        tester,
        api: FakeTodayApi(
          week: WeeklySummary(
            weekStart: DateTime(2026, 10, 5),
            summary: 'A week of planning the demo.',
            highlights: const ['Demo moved to Friday'],
            people: const ['Marco', 'Ada'],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Week of Oct 5'), findsOneWidget);
      expect(find.text('With Marco, Ada'), findsOneWidget);
      expect(find.text('• Demo moved to Friday'), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('weekly-summary-content')));
      await tester.tap(find.byKey(const Key('weekly-summary-content')));
      await tester.pumpAndSettle();
      expect(find.text('• Demo moved to Friday'), findsOneWidget);
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

    testWidgets('no weekly section before the first weekly summary', (tester) async {
      await pumpToday(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('weekly-summary')), findsNothing);
    });

    testWidgets('empty and error states', (tester) async {
      await pumpToday(tester);
      await tester.pumpAndSettle();
      expect(find.text('Echo writes a summary of each day overnight.'), findsOneWidget);

      final api = FakeTodayApi()..digestError = serverError('Digest down');
      await tester.pumpWidget(const SizedBox());
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();
      expect(find.text('Digest down'), findsOneWidget);
      api
        ..digestError = null
        ..digest = DailySummary(date: DateTime(2026, 10, 13), summary: 'Recovered.');
      await tester.ensureVisible(find.byKey(const Key('summary-retry')));
      await tester.tap(find.byKey(const Key('summary-retry')));
      await tester.pumpAndSettle();
      expect(find.text('Recovered.'), findsOneWidget);
    });
  });

  testWidgets('a full Today fits 320 wide at 1.3 text scale', (tester) async {
    final api = FakeTodayApi(
      conversations: [
        card('c1', startedAt: DateTime(2026, 10, 14, 12),
            title: 'A long conversation title about many things at once',
            people: const ['Alessandro', 'Margherita', 'Bartolomeo', 'Ada']),
      ],
      openTasks: [
        task('t1', 'A rather long task name that needs to wrap on a small screen',
            due: DateTime(2026, 10, 10), source: '[Tu] Una frase lunga da cui nasce il task.'),
      ],
      digest: DailySummary(date: DateTime(2026, 10, 13), summary: 'A long summary. ' * 20),
      week: WeeklySummary(
        weekStart: DateTime(2026, 10, 5),
        summary: 'A long week. ' * 20,
        highlights: const ['A long highlight that has to wrap on a small screen'],
        people: const ['Alessandro', 'Margherita', 'Bartolomeo', 'Ada'],
      ),
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
