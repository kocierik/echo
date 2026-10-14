import 'dart:async';

import 'package:echo_app/models/segment.dart';
import 'package:echo_app/screens/transcripts_screen.dart';
import 'package:echo_app/services/transcript_controller.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows loading, error, retry, and empty states', (tester) async {
    final pending = Completer<List<RecentSegment>>();
    await _pumpScreen(tester, api: _QueueTranscriptApi([pending.future]));
    expect(find.byKey(const Key('transcripts-loading')), findsOneWidget);

    pending.completeError(Exception('Network unavailable'));
    await tester.pump();
    expect(find.text('Could not load transcripts'), findsOneWidget);
    expect(find.text('Network unavailable'), findsOneWidget);

    final api = _QueueTranscriptApi([
      // ignore() keeps the error from being reported before the screen listens
      Future<List<RecentSegment>>.error(Exception('Try again'))..ignore(),
      Future.value(const []),
    ]);
    // Unmount the first screen, or its state (and api) would be reused
    await tester.pumpWidget(const SizedBox());
    await _pumpScreen(tester, api: api);
    await tester.pump();
    await tester.tap(find.byKey(const Key('transcripts-retry')));
    await tester.pump();

    expect(api.calls, 2);
    expect(find.text('No transcripts yet'), findsOneWidget);
  });

  testWidgets('renders newest groups, pending status, and speaker labels',
      (tester) async {
    final now = DateTime.now();
    final todayAtTen = DateTime(now.year, now.month, now.day, 10);
    final yesterdayAtTen = todayAtTen.subtract(const Duration(days: 1));
    await _pumpScreen(
      tester,
      api: _StaticTranscriptApi([
        _segment(
          'yesterday',
          yesterdayAtTen,
          text: '[Altri] Yesterday memory',
          speaker: 'other',
        ),
        _segment(
          'pending',
          todayAtTen.subtract(const Duration(minutes: 1)),
          status: 'processing',
          text: null,
          speaker: 'unknown',
          conversationId: null,
        ),
        _segment(
          'completed',
          todayAtTen,
          text: '[Tu] Current memory',
          speaker: 'self',
        ),
      ]),
    );
    await tester.pump();

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);
    expect(find.text('Transcribing'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
    expect(find.bySemanticsLabel('10:00, Current memory, Completed, You'),
        findsOneWidget);

    final todayY = tester.getTopLeft(find.text('TODAY')).dy;
    final currentY = tester.getTopLeft(find.text('Current memory')).dy;
    final yesterdayY = tester.getTopLeft(find.text('YESTERDAY')).dy;
    expect(todayY, lessThan(currentY));
    expect(currentY, lessThan(yesterdayY));
  });

  testWidgets('search filters locally and shows no results after debounce',
      (tester) async {
    final scheduler = _FakeDebounceScheduler();
    final api = _StaticTranscriptApi([
      _segment('atlas', DateTime.now(),
          text: '[Tu] Project Atlas', speaker: 'self'),
      _segment('groceries', DateTime.now().subtract(const Duration(minutes: 1)),
          text: '[Altri] Grocery list', speaker: 'other'),
    ]);
    final controller = TranscriptController(
      api: api,
      debounceScheduler: scheduler.schedule,
    );
    addTearDown(controller.dispose);
    await _pumpScreen(tester, controller: controller, api: api);
    await tester.pump();

    await tester.tap(find.byKey(const Key('transcripts-search-toggle')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('transcripts-search-field')),
      'atlas',
    );
    await tester.pump();
    expect(find.byKey(const Key('transcripts-searching')), findsOneWidget);

    scheduler.fireLatest();
    await tester.pump();
    expect(find.text('Project Atlas'), findsOneWidget);
    expect(find.text('Grocery list'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('transcripts-search-field')),
      'not here',
    );
    scheduler.fireLatest();
    await tester.pump();
    expect(find.text('No matching transcripts'), findsOneWidget);
  });

  testWidgets('long transcript has no overflow at 320px and text scale 1.3',
      (tester) async {
    await _pumpScreen(
      tester,
      api: _StaticTranscriptApi([
        _segment(
          'long',
          DateTime.now(),
          text: '[Tu] ${List.filled(30, 'a detailed memory').join(' ')}',
          speaker: 'self',
        ),
      ]),
      size: const Size(320, 812),
      textScale: 1.3,
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('chevron opens detail and refreshes after returning',
      (tester) async {
    final api = _StaticTranscriptApi([
      _segment('open', DateTime.now(), text: 'Open this memory'),
    ]);
    await _pumpScreen(
      tester,
      api: api,
      detailBuilder: (_, segment) => Scaffold(
        body: Center(child: Text('Detail ${segment.id}')),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('open-transcript-open')));
    await tester.pumpAndSettle();
    expect(find.text('Detail open'), findsOneWidget);

    Navigator.of(tester.element(find.text('Detail open'))).pop();
    await tester.pumpAndSettle();
    expect(api.calls, 2);
  });

  testWidgets('upload event triggers one refresh', (tester) async {
    final uploads = StreamController<Object?>();
    addTearDown(uploads.close);
    final api = _StaticTranscriptApi(const []);
    await _pumpScreen(
      tester,
      api: api,
      uploadStream: uploads.stream,
    );
    await tester.pump();
    expect(api.calls, 1);

    uploads.add(1);
    await tester.pump();
    await tester.pump();
    expect(api.calls, 2);
  });

  testWidgets('basic list renders in light and dark themes', (tester) async {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      await _pumpScreen(
        tester,
        api: _StaticTranscriptApi([
          _segment('theme', DateTime.now(), text: 'Theme memory'),
        ]),
        theme: theme,
      );
      await tester.pump();

      expect(find.text('Theme memory'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  TranscriptController? controller,
  required TranscriptApi api,
  Stream<Object?>? uploadStream,
  TranscriptDetailBuilder? detailBuilder,
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
        body: TranscriptsScreen(
          controller: controller,
          api: api,
          segmentUploadedStream: uploadStream,
          detailBuilder: detailBuilder,
        ),
      ),
    ),
  ));
}

RecentSegment _segment(
  String id,
  DateTime recordedAt, {
  String status = 'completed',
  String? text = 'Memory',
  String? speaker = 'unknown',
  String? conversationId = 'conversation',
}) {
  return RecentSegment(
    id: id,
    receivedAt: recordedAt.add(const Duration(seconds: 1)),
    recordedAt: recordedAt,
    durationMs: 1200,
    transcriptionStatus: status,
    text: text,
    speaker: speaker,
    conversationId: conversationId,
  );
}

final class _StaticTranscriptApi implements TranscriptApi {
  _StaticTranscriptApi(this.segments);

  final List<RecentSegment> segments;
  var calls = 0;

  @override
  Future<List<RecentSegment>> getRecentSegments({int limit = 50}) async {
    calls++;
    return segments;
  }
}

final class _QueueTranscriptApi implements TranscriptApi {
  _QueueTranscriptApi(this.responses);

  final List<Future<List<RecentSegment>>> responses;
  var calls = 0;

  @override
  Future<List<RecentSegment>> getRecentSegments({int limit = 50}) {
    return responses[calls++];
  }
}

final class _FakeDebounceScheduler {
  final tasks = <_ScheduledSearch>[];

  void Function() schedule(Duration delay, void Function() callback) {
    final task = _ScheduledSearch(callback);
    tasks.add(task);
    return task.cancel;
  }

  void fireLatest() => tasks.last.fire();
}

final class _ScheduledSearch {
  _ScheduledSearch(this.callback);

  final VoidCallback callback;
  bool cancelled = false;

  void cancel() => cancelled = true;

  void fire() {
    if (!cancelled) callback();
  }
}