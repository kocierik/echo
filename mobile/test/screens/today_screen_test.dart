import 'dart:async';

import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/person.dart';
import 'package:echo_app/models/photo.dart';
import 'package:echo_app/models/plan.dart';
import 'package:echo_app/models/routine.dart';
import 'package:echo_app/models/routine_run.dart';
import 'package:echo_app/services/memory/memories_controller.dart';
import 'package:echo_app/widgets/panel.dart';
import 'package:echo_app/models/today_insights.dart';
import 'package:echo_app/models/today_layout.dart';
import 'package:echo_app/services/app/today_layout_store.dart';
import 'package:echo_app/screens/home_screen.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/plan_test.dart' show planJson;
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
  var phoneReads = 0;

  Future<void> pumpToday(
    WidgetTester tester, {
    FakeTodayApi? api,
    DeviceStatus status = listening,
    Future<void> Function()? onReconnect,
    Stream<Object?>? uploads,
    ThemeData? theme,
    Size size = const Size(375, 812),
    double textScale = 1,
    List<Map<String, Object?>> phoneEvents = const [],
    MemoriesController? memories,
    ValueListenable<int>? routineRunsChanged,
    TodayLayout? layout,
    DateTime Function()? clock,
    TodayLayoutStore? layoutStore,
  }) async {
    phoneReads = 0;
    SharedPreferences.setMockInitialValues({
      if (layout != null) TodayLayoutStore.key: layout.toJson(),
    });
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
            onOpenTasks: () => calls.add('tasks'),
            onOpenChat: (id) => calls.add('chat $id'),
            workingPollInterval: const Duration(seconds: 1),
            openConversation: (context, id) async => calls.add('open $id'),
            segmentUploadedStream: uploads,
            clock: clock ?? () => now,
            phoneEvents: () async {
              phoneReads++;
              return phoneEvents;
            },
            memories: memories,
            routineRunsChanged: routineRunsChanged,
            onOpenThread: (id) => calls.add('thread $id'),
            layoutStore: layoutStore ?? TodayLayoutStore(),
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

  group('top', () {
    testWidgets('the day as the title, no greeting', (tester) async {
      await pumpToday(tester);
      await tester.pumpAndSettle();
      expect(find.text('Wednesday 14 October'), findsOneWidget);
      expect(find.text('Good evening'), findsNothing);
    });

    testWidgets('one card: what to confirm first, the others one tap away', (tester) async {
      final api = FakeTodayApi(
        conversations: [card('lunch', startedAt: DateTime(2026, 10, 14, 12, 30))],
        pending: [
          PendingAction(id: 'late', summary: 'Book the dinner', status: 'pending',
              expiresAt: DateTime(2026, 10, 14, 18, 30)),
          PendingAction(id: 'soon', summary: 'Email Ada', status: 'pending',
              expiresAt: DateTime(2026, 10, 14, 18, 5)),
        ],
      );
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('today-top-card')), findsOneWidget);
      expect(find.text('Email Ada'), findsOneWidget);
      expect(find.text('Book the dinner'), findsNothing);

      await tester.tap(find.text('+1 more'));
      await tester.pumpAndSettle();
      expect(find.text('Book the dinner'), findsOneWidget);
      await tester.tap(find.byKey(const Key('action-confirm-late')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('confirm late'));
    });

    testWidgets('nothing to confirm: no card on top, the day in Your day', (tester) async {
      final api = FakeTodayApi(conversations: [
        card('lunch', startedAt: DateTime(2026, 10, 14, 12, 30), duration: const Duration(hours: 1)),
      ]);
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('today-top-card')), findsNothing);
      expect(find.text('SO FAR TODAY'), findsNothing);
      expect(find.text('Lunch with Ada'), findsOneWidget);
    });

    testWidgets("the conversation going on: its time keeps up with the clock", (tester) async {
      var clock = now;
      final api = FakeTodayApi(conversations: [
        card('live', startedAt: DateTime(2026, 10, 14, 17, 48), title: 'Call about Atlas',
            isOpen: true, people: const ['Marco']),
      ]);
      await pumpToday(tester, api: api, clock: () => clock);
      await tester.pumpAndSettle();
      expect(find.text('Now · 12 min'), findsOneWidget);

      clock = now.add(const Duration(minutes: 5));
      await tester.pump(const Duration(minutes: 1));

      expect(find.text('Now · 17 min'), findsOneWidget);
    });

    testWidgets('the conversation going on, with the last line heard', (tester) async {
      final api = FakeTodayApi(conversations: [
        card('live', startedAt: DateTime(2026, 10, 14, 17, 48), title: 'Call about Atlas',
            isOpen: true, people: const ['Marco']),
      ])
        ..details['live'] = ConversationDetail(
          card: card('live', startedAt: DateTime(2026, 10, 14, 17, 48), isOpen: true),
          lines: [
            TranscriptLine(segmentId: 's1', recordedAt: DateTime(2026, 10, 14, 17, 59),
                status: 'completed', text: '[Others] so we move the demo to November'),
          ],
          entities: const [],
        );
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();

      // In Your day's live row, not in a card on top
      expect(find.byKey(const Key('today-top-card')), findsNothing);
      final live = find.byKey(const Key('day-now'));
      await tester.ensureVisible(live);
      for (final text in ['Now · 12 min', 'Call about Atlas', 'with Marco']) {
        expect(find.descendant(of: live, matching: find.text(text)), findsOneWidget, reason: text);
      }
      expect(
        find.descendant(
          of: live,
          matching: find.textContaining('so we move the demo to November', findRichText: true),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the live transcript follows the conversation, turn by turn', (tester) async {
      ConversationDetail detail(List<TranscriptLine> lines) => ConversationDetail(
            card: card('live', startedAt: DateTime(2026, 10, 14, 17, 48), isOpen: true),
            lines: lines,
            entities: const [],
          );
      final api = FakeTodayApi(conversations: [
        card('live', startedAt: DateTime(2026, 10, 14, 17, 48), isOpen: true),
      ])
        ..details['live'] = detail([
          TranscriptLine(segmentId: 's1', recordedAt: DateTime(2026, 10, 14, 17, 59),
              status: 'completed', text: '[You] Ciao.', speaker: 'self'),
        ]);
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('day-now-line-0')), findsOneWidget);
      expect(find.byKey(const Key('day-now-line-1')), findsNothing);

      // A segment where two spoke arrives: each turn its line, the last three shown
      api.details['live'] = detail([
        TranscriptLine(segmentId: 's1', recordedAt: DateTime(2026, 10, 14, 17, 59),
            status: 'completed', text: '[You] Ciao.', speaker: 'self'),
        TranscriptLine(
          segmentId: 's2', recordedAt: DateTime(2026, 10, 14, 18), status: 'completed',
          text: '[You] Hai i numeri? Sì, eccoli.', speaker: 'self',
          turns: const [
            Turn(speaker: 'self', text: 'Hai i numeri?'),
            Turn(speaker: 'other', speakerName: 'Person 2', text: 'Sì, eccoli.'),
          ],
        ),
      ]);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('day-now-line-2')), findsOneWidget);
      expect(find.byKey(const Key('day-now-line-3')), findsNothing);
      expect(find.textContaining('Person 2', findRichText: true), findsOneWidget);
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
      await tester.pumpAndSettle();
      // The whole of today, on a page of its own
      expect(find.byKey(const Key('day-screen')), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
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
      // Nothing yet today: no empty panel
      expect(find.byKey(const Key('your-day')), findsNothing);

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

  group('from your routines', () {
    RoutineRun run(String id, {String status = 'reported'}) => RoutineRun(
          id: id,
          routineId: 'rt1',
          instruction: 'dimmi se piove domani',
          mode: 'only_if',
          scheduleText: 'Every day at 07:00',
          ranAt: DateTime(2026, 10, 14, 7),
          status: status,
          text: status == 'reported' ? 'Domani piove dalle 15' : null,
        );

    testWidgets("today's runs, above To do today", (tester) async {
      final api = _RoutinesTodayApi([run('r1')], openTasks: [
        task('today', 'Call Ada', due: DateTime(2026, 10, 14)),
      ]);
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();

      expect(api.since, [DateTime(2026, 10, 14)]);
      final panel = find.byKey(const Key('routines-today'));
      expect(panel, findsOneWidget);
      expect(
        tester.getTopLeft(panel).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('todo-panel'))).dy),
      );
    });

    testWidgets('no runs today, no panel', (tester) async {
      await pumpToday(tester, api: _RoutinesTodayApi(const []));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('routines-today')), findsNothing);
    });

    testWidgets('new runs reload the panel', (tester) async {
      final api = _RoutinesTodayApi(const []);
      final changes = ValueNotifier(0);
      addTearDown(changes.dispose);
      await pumpToday(tester, api: api, routineRunsChanged: changes);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('routines-today')), findsNothing);

      api.runs = [run('r1')];
      changes.value++;
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('routines-today')), findsOneWidget);
    });

    testWidgets('a row opens the whole result; Ask about this opens the thread',
        (tester) async {
      final api = _RoutinesTodayApi([run('r1')]);
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('routine-run-r1')));
      await tester.tap(find.byKey(const Key('routine-run-r1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('run-ask-about')));
      await tester.pumpAndSettle();

      expect(api.asked, ['r1']);
      expect(calls, contains('thread thread-1'));
    });

    testWidgets('Ask about this failing says so', (tester) async {
      final api = _RoutinesTodayApi([run('r1')])..askFails = true;
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('routine-run-r1')));
      await tester.tap(find.byKey(const Key('routine-run-r1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('run-ask-about')));
      await tester.pumpAndSettle();

      expect(find.text('Could not open it in Ask.'), findsOneWidget);
      expect(calls.where((c) => c.startsWith('thread')), isEmpty);
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

    testWidgets('nothing due, and See all; no panel without anything open', (tester) async {
      await pumpToday(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('todo-panel')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await pumpToday(tester, api: FakeTodayApi(openTasks: [
        task('later', 'Renew the passport', due: DateTime(2026, 11, 30)),
      ]));
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

  group('the memory', () {
    testWidgets('search over the whole memory, from the icon on top', (tester) async {
      final api = FakeTodayApi(conversations: [card('c1', startedAt: DateTime(2026, 10, 14, 9))])
        ..searchResults = MemorySearchResults(
          conversations: [card('hit', startedAt: DateTime(2026, 10, 12, 9), title: 'Atlas kickoff')],
          entities: const [
            MemoryEntity(
              id: 'e1',
              type: 'idea',
              name: 'Atlas dashboard',
              sourceText: '[Tu] Facciamo una dashboard per Atlas.',
              conversationId: 'hit',
            ),
          ],
        );
      late void Function() runSearch;
      final memories = MemoriesController(
        api: api,
        debounceScheduler: (delay, callback) {
          runSearch = callback;
          return () {};
        },
      );
      addTearDown(memories.dispose);
      await pumpToday(tester, api: api, memories: memories);
      await tester.pumpAndSettle();
      // Not a field on Today any more: an icon in the header
      expect(find.byKey(const Key('memories-search')), findsNothing);
      await tester.tap(find.byKey(const Key('today-search')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('memories-search')), 'atlas');
      await tester.pump();
      expect(find.byKey(const Key('search-loading')), findsOneWidget);
      runSearch();
      await tester.pumpAndSettle();

      expect(find.widgetWithText(PanelHeader, 'Conversations'), findsOneWidget);
      expect(find.text('Atlas kickoff'), findsOneWidget);
      expect(find.text('Atlas dashboard'), findsOneWidget);
      expect(find.byKey(const Key('your-day')), findsNothing);
      await tester.tap(find.text('Atlas dashboard'));
      await tester.pumpAndSettle();
      expect(calls, ['open hit']);

      api.searchResults = const MemorySearchResults(conversations: [], entities: []);
      await tester.enterText(find.byKey(const Key('memories-search')), 'zzz');
      await tester.pump();
      runSearch();
      await tester.pumpAndSettle();
      expect(find.text('No results'), findsOneWidget);

      await tester.tap(find.byKey(const Key('memories-search-clear')));
      await tester.pumpAndSettle();
      expect(find.text('No results'), findsNothing);

      // Back on Today, the search is over
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(memories.state.query, isEmpty);
      expect(find.byKey(const Key('your-day')), findsOneWidget);
    });

    testWidgets('past the speech budget: a quiet line, opening the plan', (tester) async {
      await pumpToday(tester, api: _PlanTodayApi(PlanInfo.fromJson(planJson(
        plan: 'free',
        monthly: 300 * 60,
        used: 300 * 60,
        over: true,
      ))));
      await tester.pumpAndSettle();

      expect(find.text('Echo is transcribing 10 minutes a day until 1 November.'),
          findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('plan-line')));
      await tester.tap(find.byKey(const Key('plan-line')));
      await tester.pumpAndSettle();
      expect(find.text('Starts again on 1 November.'), findsOneWidget);
    });

    testWidgets('near the budget: how much is used, before it runs out', (tester) async {
      await pumpToday(tester, api: _PlanTodayApi(PlanInfo.fromJson(planJson(used: 21 * 3600))));
      await tester.pumpAndSettle();

      expect(find.text('21 h of this month\'s 25 h of speech used.'), findsOneWidget);
    });

    testWidgets('well within the budget: no line', (tester) async {
      await pumpToday(tester, api: _PlanTodayApi(PlanInfo.fromJson(planJson())));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('plan-line')), findsNothing);
    });

    testWidgets('a photo of the day shows its thumbnail and title', (tester) async {
      final api = _PhotoTodayApi(conversations: [
        card('photo', startedAt: DateTime(2026, 10, 14, 10, 15), title: 'the lift notice',
            summary: 'Out of order until Thursday', photoId: 'p1', segmentCount: 0),
      ]);
      await pumpToday(tester, api: api);
      await tester.pumpAndSettle();

      expect(find.text('Photo: the lift notice'), findsOneWidget);
      expect(find.text('Out of order until Thursday'), findsOneWidget);
      expect(find.byKey(const Key('day-photo-p1')), findsOneWidget);
    });
  });

  testWidgets('"Echo can act in" moved to Profile → Apps', (tester) async {
    await pumpToday(tester, api: _ToolkitsTodayApi(const []));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('acts-in')), findsNothing);
  });

  testWidgets('working requests are not on Today any more', (tester) async {
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

    expect(find.text('📷 Taking a photo: Che pianta è?'), findsNothing);
    expect(find.byKey(const Key('working-section')), findsNothing);
  });

  group('in your order', () {
    FakeTodayApi full() => FakeTodayApi(
          conversations: [
            card('lunch', startedAt: DateTime(2026, 10, 14, 12, 30), people: const ['Ada']),
          ],
          openTasks: [task('today', 'Call Ada', due: DateTime(2026, 10, 14))],
        )..people = [
            PersonSummary(id: 'p1', name: 'Ada', lastSeen: DateTime(2026, 10, 14, 12, 30)),
          ];

    double top(WidgetTester tester, String key) => tester.getTopLeft(find.byKey(Key(key))).dy;

    testWidgets('sections follow the saved order', (tester) async {
      tester.view.physicalSize = const Size(375, 2400);
      await pumpToday(
        tester,
        api: full(),
        size: const Size(375, 2400),
        layout: const TodayLayout(order: [
          TodaySection.yourDay,
          TodaySection.todo,
          TodaySection.routines,
          TodaySection.comingUp,
        ]),
      );
      await tester.pumpAndSettle();

      expect(top(tester, 'your-day'), lessThan(top(tester, 'todo-panel')));
    });

    testWidgets('a hidden section is not shown', (tester) async {
      await pumpToday(tester, api: full(), layout: TodayLayout.defaults.toggled(TodaySection.todo));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('todo-panel')), findsNothing);
      expect(find.byKey(const Key('your-day')), findsOneWidget);
    });

    testWidgets('with every section hidden Edit Today is still there', (tester) async {
      var layout = TodayLayout.defaults;
      for (final section in TodaySection.values) {
        layout = layout.toggled(section);
      }
      final api = full()
        ..pending.add(PendingAction(id: 'a1', summary: 'Email Ada', status: 'pending',
            expiresAt: DateTime(2026, 10, 14, 18, 30)));
      await pumpToday(tester, api: api, layout: layout);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('today-top-card')), findsOneWidget);
      expect(find.byKey(const Key('your-day')), findsNothing);
      expect(find.byKey(const Key('today-edit')), findsOneWidget);
    });

    testWidgets('a hidden agenda reads no calendar; shown again, it loads', (tester) async {
      final api = FakeTodayApi()
        ..upcoming = ComingUp(title: 'Review with Ada', start: DateTime(2026, 10, 14, 18, 30));
      final events = [
        {
          'id': 'E1',
          'title': 'Review with Ada',
          'start': DateTime(2026, 10, 14, 18, 30).toUtc().toIso8601String(),
        },
      ];
      await pumpToday(tester, api: api, phoneEvents: events,
          layout: TodayLayout.defaults.toggled(TodaySection.comingUp));
      await tester.pumpAndSettle();

      expect(phoneReads, 0);
      expect(api.comingUpEvents, isEmpty);

      await tester.scrollUntilVisible(find.byKey(const Key('today-edit')), 200,
          scrollable: find.descendant(
              of: find.byKey(const Key('today')), matching: find.byType(Scrollable)).first);
      await tester.tap(find.byKey(const Key('today-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('edit-today-switch-comingUp')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(phoneReads, 1);
      expect(find.byKey(const Key('coming-up-today')), findsOneWidget);
    });

    testWidgets('a hidden section never shows, not even before the layout is read',
        (tester) async {
      final prefs = Completer<SharedPreferences>();
      await pumpToday(
        tester,
        api: full(),
        layout: TodayLayout.defaults.toggled(TodaySection.todo),
        layoutStore: TodayLayoutStore(preferences: () => prefs.future),
      );
      await tester.pump();

      expect(find.byKey(const Key('todo-panel')), findsNothing);

      prefs.complete(await SharedPreferences.getInstance());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('todo-panel')), findsNothing);
      expect(find.byKey(const Key('your-day')), findsOneWidget);
    });

    testWidgets('Edit Today saves the new layout', (tester) async {
      await pumpToday(tester, api: full());
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.byKey(const Key('today-edit')), 200,
          scrollable: find.descendant(
              of: find.byKey(const Key('today')), matching: find.byType(Scrollable)).first);
      await tester.tap(find.byKey(const Key('today-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('edit-today-switch-todo')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('todo-panel')), findsNothing);
      final saved = (await SharedPreferences.getInstance()).getString(TodayLayoutStore.key);
      expect(TodayLayout.fromJson(saved).isHidden(TodaySection.todo), isTrue);
    });

    testWidgets('the agenda lists what is still to come today', (tester) async {
      final api = FakeTodayApi()
        ..upcoming = ComingUp(
            title: 'Review with Ada', start: DateTime(2026, 10, 14, 18, 30),
            recap: 'Last time: the budget');
      String at(int hour, [int minute = 0]) =>
          DateTime(2026, 10, 14, hour, minute).toUtc().toIso8601String();
      final events = [
        {'id': 'E0', 'title': 'Stand-up', 'start': at(9)},
        {'id': 'E1', 'title': 'Review with Ada', 'start': at(18, 30)},
        {'id': 'E2', 'title': 'Dinner', 'start': at(20)},
      ];
      await pumpToday(tester, api: api, phoneEvents: events);
      await tester.pumpAndSettle();

      // What was said last time: asked for the event within the hour only
      expect(api.comingUpEvents, [
        [events[1]],
      ]);
      final agenda = find.byKey(const Key('coming-up-today'));
      expect(agenda, findsOneWidget);
      expect(find.descendant(of: agenda, matching: find.text('Review with Ada')), findsOneWidget);
      expect(find.descendant(of: agenda, matching: find.text('Dinner')), findsOneWidget);
      expect(find.descendant(of: agenda, matching: find.text('Stand-up')), findsNothing);
      expect(find.text('Last time: the budget'), findsOneWidget);
    });

    testWidgets('the next morning, yesterday is gone and today loads when the app comes back',
        (tester) async {
      var clock = DateTime(2026, 10, 14, 18);
      String at(DateTime time) => time.toUtc().toIso8601String();
      var phone = [
        {'id': 'E1', 'title': 'Holiday', 'start': at(DateTime(2026, 10, 14)), 'all_day': true},
        {'id': 'E2', 'title': 'Dinner', 'start': at(DateTime(2026, 10, 14, 20))},
      ];
      final api = FakeTodayApi();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: HomeScreen(
            api: api,
            deviceStatus: listening,
            onOpenTasks: () {},
            clock: () => clock,
            phoneEvents: () async => phone,
            layoutStore: TodayLayoutStore(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Holiday'), findsOneWidget);

      // The next morning: nothing of yesterday, even before anything reloads
      clock = DateTime(2026, 10, 15, 8);
      phone = [
        {'id': 'E3', 'title': 'Dentist', 'start': at(DateTime(2026, 10, 15, 15))},
      ];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: HomeScreen(
            api: api,
            deviceStatus: listening,
            onOpenTasks: () {},
            clock: () => clock,
            phoneEvents: () async => phone,
            layoutStore: TodayLayoutStore(),
          ),
        ),
      ));
      expect(find.text('Holiday'), findsNothing);

      // Back in the app: today's agenda
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(find.text('Dentist'), findsOneWidget);
    });

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
    super.conversations,
    super.openTasks,
    super.pending,
  });

  final List<Toolkit> toolkits;

  @override
  Future<List<Toolkit>> getToolkits({String? query}) async {
    return toolkits;
  }
}

/// Today with the photos' images (a photo row's thumbnail).
final class _PhotoTodayApi extends FakeTodayApi implements PhotoApi {
  _PhotoTodayApi({super.conversations});

  @override
  Future<PhotoImageSource> photoImage(String id) async => PhotoImageSource(
        url: Uri.parse('https://echo.test/api/photos/$id/image'),
        headers: const {},
      );

  @override
  Future<PhotoInfo> requestPhoto({
    String? question,
    String? chatSessionId,
    bool fromWearableButton = false,
    String source = 'app',
  }) =>
      throw UnimplementedError();

  @override
  Future<PhotoInfo> getPhoto(String id) => throw UnimplementedError();

  @override
  Future<void> uploadPhoto(String id, List<int> jpeg, DateTime capturedAt) =>
      throw UnimplementedError();

  @override
  Future<void> reportPhotoFailure(String id, String reason) => throw UnimplementedError();
}

/// Today's API with the plan.
final class _PlanTodayApi extends FakeTodayApi implements PlanApi {
  _PlanTodayApi(this.plan);

  final PlanInfo plan;

  @override
  Future<PlanInfo> getPlan() async => plan;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Today's API with routines and their runs.
final class _RoutinesTodayApi extends FakeTodayApi implements RoutinesApi {
  _RoutinesTodayApi(this.runs, {super.openTasks});

  List<RoutineRun> runs;
  final since = <DateTime?>[];
  final asked = <String>[];
  bool askFails = false;

  @override
  Future<RoutineRunPage> listRoutineRuns({
    String? routineId,
    DateTime? since,
    DateTime? before,
    int limit = 30,
  }) async {
    this.since.add(since);
    return RoutineRunPage(items: runs);
  }

  @override
  Future<String> askAboutRoutineRun(String runId) async {
    if (askFails) throw Exception('offline');
    asked.add(runId);
    return 'thread-1';
  }

  @override
  Future<List<Routine>> listRoutines() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
