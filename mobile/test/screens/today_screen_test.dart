import 'dart:async';

import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/models/segment.dart';
import 'package:echo_app/models/task_item.dart';
import 'package:echo_app/models/today_insights.dart';
import 'package:echo_app/screens/home_screen.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const listening = DeviceStatus(
    connectionState: DeviceConnectionState.listening,
  );
  const muted = DeviceStatus(
    connectionState: DeviceConnectionState.muted,
  );
  const connecting = DeviceStatus(
    connectionState: DeviceConnectionState.connecting,
  );
  const offline = DeviceStatus(
    connectionState: DeviceConnectionState.offline,
  );

  testWidgets('four Today states fit supported light and dark viewports', (
    tester,
  ) async {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      for (final viewport in const [
        (size: Size(375, 812), textScale: 1.0),
        (size: Size(320, 812), textScale: 1.3),
      ]) {
        for (final status in [listening, muted, connecting, offline]) {
          await _pumpToday(
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

  testWidgets('mute waits for telemetry acknowledgement before changing state', (
    tester,
  ) async {
    final writes = <bool>[];
    Future<void> setMuted(bool value) async => writes.add(value);

    await _pumpToday(tester, status: listening, setMuted: setMuted);
    await tester.tap(find.text('Mute microphone'));
    await tester.pump();

    expect(writes, [true]);
    expect(find.text('Listening'), findsOneWidget);
    expect(find.text('Mute microphone'), findsOneWidget);

    await _pumpToday(tester, status: muted, setMuted: setMuted);

    expect(find.text('Microphone muted'), findsOneWidget);
    expect(find.text('Resume listening'), findsOneWidget);
    expect(find.byKey(const Key('privacy-progress')), findsNothing);
  });

  testWidgets('resume command sends false', (tester) async {
    final writes = <bool>[];
    await _pumpToday(
      tester,
      status: muted,
      setMuted: (value) async => writes.add(value),
    );

    await tester.tap(find.text('Resume listening'));
    await tester.pump();

    expect(writes, [false]);
    expect(find.text('Microphone muted'), findsOneWidget);

    await _pumpToday(tester, status: listening, setMuted: (value) async {});
  });

  testWidgets('failed mute command exposes a retry without haptic success', (
    tester,
  ) async {
    var attempts = 0;
    await _pumpToday(
      tester,
      status: listening,
      setMuted: (_) async {
        attempts++;
        if (attempts == 1) throw StateError('write failed');
      },
    );

    await tester.tap(find.text('Mute microphone'));
    await tester.pump();

    expect(find.text('Echo could not update the microphone.'), findsOneWidget);
    expect(find.byKey(const Key('privacy-retry')), findsOneWidget);

    // Today now has tasks and the summary: the retry sits below the fold
    await tester.ensureVisible(find.byKey(const Key('privacy-retry')));
    await tester.tap(find.byKey(const Key('privacy-retry')));
    await tester.pump();
    expect(attempts, 2);

    await _pumpToday(tester, status: muted, setMuted: (_) async {});
  });

  testWidgets('connecting disables the privacy action', (tester) async {
    final writes = <bool>[];
    await _pumpToday(
      tester,
      status: connecting,
      setMuted: (value) async => writes.add(value),
    );

    expect(find.text('Connecting…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('privacy-action')));
    await tester.pump();

    expect(writes, isEmpty);
  });

  testWidgets('offline reconnect delegates without optimistic listening state', (
    tester,
  ) async {
    var reconnects = 0;
    await _pumpToday(
      tester,
      status: offline,
      onReconnect: () async => reconnects++,
    );

    await tester.tap(find.text('Reconnect Echo'));
    await tester.pump();

    expect(reconnects, 1);
    expect(find.text('Echo is offline'), findsOneWidget);
    expect(find.text('Listening'), findsNothing);
  });

  testWidgets('latest memory shows loading, error, empty, and retry states', (
    tester,
  ) async {
    final pending = Completer<List<RecentSegment>>();
    await _pumpToday(tester, latestMemoryLoader: () => pending.future);
    expect(find.byKey(const Key('memory-loading')), findsOneWidget);

    pending.complete(const []);
    await tester.pump();
    expect(find.text('No completed memories yet.'), findsOneWidget);

    var attempts = 0;
    // Unmount the first screen, or its state (and loader) would be reused
    await tester.pumpWidget(const SizedBox());
    await _pumpToday(
      tester,
      latestMemoryLoader: () async {
        attempts++;
        if (attempts == 1) throw StateError('offline');
        return const [];
      },
    );
    await tester.pump();
    expect(find.text('Could not load the latest memory.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-retry')));
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('No completed memories yet.'), findsOneWidget);
  });

  testWidgets('latest memory chooses completed nonempty content and opens detail', (
    tester,
  ) async {
    var loads = 0;
    await _pumpToday(
      tester,
      latestMemoryLoader: () async {
        loads++;
        return [
          _segment(status: 'processing', text: 'Still processing'),
          _segment(id: 'empty', text: '   '),
          _segment(
            id: 'latest',
            text: '[You] Project Atlas is ready for review.',
            speaker: 'self',
          ),
        ];
      },
    );
    await tester.pump();

    expect(find.text('Project Atlas is ready for review.'), findsOneWidget);
    // The speaker shares a line with the time: "10:00  ·  You"
    expect(find.textContaining('·  You'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-content')));
    await tester.pumpAndSettle();
    expect(find.text('Transcript'), findsOneWidget);

    Navigator.of(tester.element(find.text('Transcript'))).pop();
    await tester.pumpAndSettle();
    expect(loads, 2);
  });

  testWidgets('segment upload refreshes latest memory once per event', (
    tester,
  ) async {
    final uploads = StreamController<int>();
    addTearDown(uploads.close);
    var loads = 0;
    await _pumpToday(
      tester,
      segmentUploadedStream: uploads.stream,
      latestMemoryLoader: () async {
        loads++;
        return const [];
      },
    );
    await tester.pump();
    expect(loads, 1);

    uploads.add(1);
    await tester.pump();
    await tester.pump();
    expect(loads, 2);
  });

  testWidgets('open tasks show loading then empty state', (tester) async {
    final pending = Completer<List<TaskItem>>();
    await _pumpToday(tester, openTasksLoader: () => pending.future);
    expect(find.byKey(const Key('tasks-loading')), findsOneWidget);

    pending.complete(const []);
    await tester.pump();
    expect(find.text('No open tasks.'), findsOneWidget);
  });

  testWidgets('open tasks error offers a retry', (tester) async {
    var attempts = 0;
    await _pumpToday(
      tester,
      openTasksLoader: () async {
        attempts++;
        if (attempts == 1) throw StateError('offline');
        return const [TaskItem(id: 't1', name: 'Call Ada')];
      },
    );
    await tester.pump();
    expect(find.text('Could not load open tasks.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tasks-retry')));
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('Call Ada'), findsOneWidget);
  });

  testWidgets('shows at most three open tasks with a count of the rest', (
    tester,
  ) async {
    await _pumpToday(
      tester,
      openTasksLoader: () async => [
        for (var i = 1; i <= 5; i++) TaskItem(id: 't$i', name: 'Task $i'),
      ],
    );
    await tester.pump();

    expect(find.text('Task 1'), findsOneWidget);
    expect(find.text('Task 3'), findsOneWidget);
    expect(find.text('Task 4'), findsNothing);
    expect(find.text('+2 more'), findsOneWidget);
  });

  testWidgets('completing a task removes it only after the backend confirms', (
    tester,
  ) async {
    final completion = Completer<void>();
    final completed = <String>[];
    await _pumpToday(
      tester,
      openTasksLoader: () async => const [
        TaskItem(id: 't1', name: 'Call Ada'),
        TaskItem(id: 't2', name: 'Book flights'),
      ],
      taskCompleter: (task) {
        completed.add(task.id);
        return completion.future;
      },
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('task-complete-t1')));
    await tester.pump();
    expect(completed, ['t1']);
    expect(find.text('Call Ada'), findsOneWidget);
    expect(find.byKey(const Key('task-complete-t1')), findsNothing);

    completion.complete();
    await tester.pump();
    expect(find.text('Call Ada'), findsNothing);
    expect(find.text('Book flights'), findsOneWidget);
  });

  testWidgets('a failed task completion keeps the task and reports it', (
    tester,
  ) async {
    await _pumpToday(
      tester,
      openTasksLoader: () async => const [TaskItem(id: 't1', name: 'Call Ada')],
      taskCompleter: (_) async => throw StateError('offline'),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('task-complete-t1')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Call Ada'), findsOneWidget);
    expect(find.byKey(const Key('task-complete-t1')), findsOneWidget);
    expect(find.text('Echo could not update the task.'), findsOneWidget);
  });

  testWidgets('daily summary shows the latest digest', (tester) async {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    await _pumpToday(
      tester,
      dailySummaryLoader: () async => DailySummary(
        date: DateTime(yesterday.year, yesterday.month, yesterday.day),
        summary: 'Reviewed Project Atlas with Ada.',
      ),
    );
    await tester.pump();
    expect(find.text('Reviewed Project Atlas with Ada.'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
  });

  testWidgets('daily summary empty state', (tester) async {
    await _pumpToday(tester, dailySummaryLoader: () async => null);
    await tester.pump();
    expect(
      find.text('No summary yet. Echo writes one each night for the day before.'),
      findsOneWidget,
    );
  });

  testWidgets('daily summary error offers a retry', (tester) async {
    var attempts = 0;
    await _pumpToday(
      tester,
      dailySummaryLoader: () async {
        attempts++;
        if (attempts == 1) throw StateError('offline');
        return null;
      },
    );
    await tester.pump();
    expect(find.text('Could not load the daily summary.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('summary-retry')));
    await tester.pump();
    expect(attempts, 2);
  });

  testWidgets('Today with tasks and summary fits small viewports', (
    tester,
  ) async {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      await _pumpToday(
        tester,
        theme: theme,
        size: const Size(320, 812),
        textScale: 1.3,
        openTasksLoader: () async => [
          for (var i = 1; i <= 4; i++)
            TaskItem(
              id: 't$i',
              name: 'A fairly long task name number $i to wrap',
              dueDate: DateTime(2026, 10, 14),
            ),
        ],
        dailySummaryLoader: () async => DailySummary(
          date: DateTime(2026, 10, 12),
          summary: 'A long summary sentence. ' * 12,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });
}

Future<void> _pumpToday(
  WidgetTester tester, {
  DeviceStatus status = const DeviceStatus(
    connectionState: DeviceConnectionState.listening,
  ),
  Future<void> Function(bool)? setMuted,
  Future<void> Function()? onReconnect,
  Future<List<RecentSegment>> Function()? latestMemoryLoader,
  Future<List<TaskItem>> Function()? openTasksLoader,
  Future<DailySummary?> Function()? dailySummaryLoader,
  Future<void> Function(TaskItem task)? taskCompleter,
  Stream<Object?>? segmentUploadedStream,
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
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: HomeScreen(
          deviceStatus: status,
          setMuted: setMuted ?? (_) async {},
          onReconnect: onReconnect,
          onAsk: () {},
          onTranscripts: () {},
          latestMemoryLoader: latestMemoryLoader ?? () async => const [],
          openTasksLoader: openTasksLoader ?? () async => const [],
          dailySummaryLoader: dailySummaryLoader ?? () async => null,
          taskCompleter: taskCompleter ?? (_) async {},
          segmentUploadedStream: segmentUploadedStream,
          onMuteAcknowledged: () async {},
        ),
      ),
    ),
  ));
  await tester.pump();
}

RecentSegment _segment({
  String id = 'segment',
  String status = 'completed',
  String? text = 'A completed memory',
  String? speaker = 'other',
}) {
  return RecentSegment(
    id: id,
    receivedAt: DateTime(2026, 10, 2, 9, 30),
    recordedAt: DateTime(2026, 10, 2, 9, 29),
    durationMs: 1200,
    transcriptionStatus: status,
    text: text,
    speaker: speaker,
    conversationId: 'conversation',
  );
}