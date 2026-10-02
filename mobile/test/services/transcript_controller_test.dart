import 'dart:async';

import 'package:echo_app/models/segment.dart';
import 'package:echo_app/services/transcript_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads at most 100 segments and groups local Today and Yesterday',
      () async {
    final api = _FakeTranscriptApi([
      _segment('older', DateTime(2026, 9, 30, 23, 59)),
      _segment('yesterday', DateTime(2026, 10, 1, 23, 59)),
      _segment('today', DateTime(2026, 10, 2)),
    ]);
    final controller = TranscriptController(
      api: api,
      clock: () => DateTime(2026, 10, 2, 0, 5),
    );
    addTearDown(controller.dispose);

    await controller.initialize();

    expect(api.limits, [100]);
    expect(
      controller.state.groups.map((group) => group.label),
      ['Today', 'Yesterday', 'Sep 30, 2026'],
    );
    expect(
      controller.state.groups.map((group) => group.day),
      [
        DateTime(2026, 10, 2),
        DateTime(2026, 10, 1),
        DateTime(2026, 9, 30),
      ],
    );
  });

  test('deduplicates by id and keeps stable newest-first order', () async {
    final sameTime = DateTime(2026, 10, 2, 10);
    final controller = TranscriptController(
      api: _FakeTranscriptApi([
        _segment('same-a', sameTime),
        _segment('newest', sameTime.add(const Duration(minutes: 1))),
        _segment('same-b', sameTime),
        _segment('same-a', sameTime.subtract(const Duration(days: 1))),
      ]),
      clock: () => DateTime(2026, 10, 2, 12),
    );
    addTearDown(controller.dispose);

    await controller.initialize();

    expect(
      controller.state.allSegments.map((segment) => segment.id),
      ['newest', 'same-a', 'same-b'],
    );
  });

  test('debounces local text and speaker search for 300ms', () async {
    final scheduler = _FakeDebounceScheduler();
    final controller = TranscriptController(
      api: _FakeTranscriptApi([
        _segment('self', DateTime(2026, 10, 2, 10),
            text: '[Tu] Project Atlas planning', speaker: 'self'),
        _segment('other', DateTime(2026, 10, 2, 9),
            text: '[Altri] Grocery list', speaker: 'other'),
      ]),
      clock: () => DateTime(2026, 10, 2, 12),
      debounceScheduler: scheduler.schedule,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    controller.setQuery('PLANNING');
    expect(controller.state.searching, isTrue);
    expect(scheduler.lastDelay, const Duration(milliseconds: 300));

    scheduler.fireLatest();
    expect(controller.state.searching, isFalse);
    expect(_visibleIds(controller), ['self']);

    controller.setQuery('you');
    scheduler.fireLatest();
    expect(_visibleIds(controller), ['self']);

    controller.setQuery('OTHER');
    scheduler.fireLatest();
    expect(_visibleIds(controller), ['other']);
  });

  test('empty query restores all groups immediately and no result stays empty',
      () async {
    final scheduler = _FakeDebounceScheduler();
    final controller = TranscriptController(
      api: _FakeTranscriptApi([
        _segment('one', DateTime(2026, 10, 2, 10), text: 'Alpha'),
        _segment('two', DateTime(2026, 10, 1, 10), text: 'Beta'),
      ]),
      clock: () => DateTime(2026, 10, 2, 12),
      debounceScheduler: scheduler.schedule,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    controller.setQuery('missing');
    scheduler.fireLatest();
    expect(controller.state.groups, isEmpty);
    expect(controller.state.allSegments, hasLength(2));

    controller.setQuery('');
    expect(controller.state.searching, isFalse);
    expect(_visibleIds(controller), ['one', 'two']);
  });

  test('stale debounce callback cannot replace a newer query', () async {
    final scheduler = _FakeDebounceScheduler();
    final controller = TranscriptController(
      api: _FakeTranscriptApi([
        _segment('alpha', DateTime(2026, 10, 2, 10), text: 'Alpha'),
        _segment('beta', DateTime(2026, 10, 2, 9), text: 'Beta'),
      ]),
      clock: () => DateTime(2026, 10, 2, 12),
      debounceScheduler: scheduler.schedule,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    controller.setQuery('alpha');
    final stale = scheduler.latest;
    controller.setQuery('beta');
    stale.fireEvenIfCancelled();

    expect(controller.state.query, 'beta');
    expect(controller.state.searching, isTrue);

    scheduler.fireLatest();
    expect(_visibleIds(controller), ['beta']);
  });

  test('stale load response cannot replace a newer refresh', () async {
    final first = Completer<List<RecentSegment>>();
    final second = Completer<List<RecentSegment>>();
    final api = _QueuedTranscriptApi([first.future, second.future]);
    final controller = TranscriptController(
      api: api,
      clock: () => DateTime(2026, 10, 2, 12),
    );
    addTearDown(controller.dispose);

    final initialLoad = controller.initialize();
    final refresh = controller.refresh();
    second.complete([
      _segment('new', DateTime(2026, 10, 2, 11)),
    ]);
    await refresh;
    first.complete([
      _segment('stale', DateTime(2026, 10, 2, 10)),
    ]);
    await initialLoad;

    expect(controller.state.allSegments.single.id, 'new');
  });

  test('owned upload stream refreshes once per upload event', () async {
    final uploads = StreamController<Object?>();
    final api = _FakeTranscriptApi(const []);
    final controller = TranscriptController(
      api: api,
      uploadStream: uploads.stream,
    );
    addTearDown(() async {
      controller.dispose();
      await uploads.close();
    });

    await controller.initialize();
    expect(api.limits, [100]);

    uploads.add(42);
    await Future<void>.value();
    expect(api.limits, [100, 100]);
  });
}

List<String> _visibleIds(TranscriptController controller) => controller
    .state.groups
    .expand((group) => group.items)
    .map((segment) => segment.id)
    .toList();

RecentSegment _segment(
  String id,
  DateTime recordedAt, {
  String? text = 'Memory',
  String? speaker = 'unknown',
}) {
  return RecentSegment(
    id: id,
    receivedAt: recordedAt.add(const Duration(seconds: 1)),
    recordedAt: recordedAt,
    durationMs: 1200,
    transcriptionStatus: 'completed',
    text: text,
    speaker: speaker,
    conversationId: 'conversation-$id',
  );
}

final class _FakeTranscriptApi implements TranscriptApi {
  _FakeTranscriptApi(this.segments);

  final List<RecentSegment> segments;
  final List<int> limits = [];

  @override
  Future<List<RecentSegment>> getRecentSegments({int limit = 50}) async {
    limits.add(limit);
    return segments;
  }
}

final class _QueuedTranscriptApi implements TranscriptApi {
  _QueuedTranscriptApi(this.responses);

  final List<Future<List<RecentSegment>>> responses;
  var calls = 0;

  @override
  Future<List<RecentSegment>> getRecentSegments({int limit = 50}) {
    return responses[calls++];
  }
}

final class _FakeDebounceScheduler {
  final tasks = <_FakeScheduledTask>[];
  Duration? lastDelay;

  _FakeScheduledTask get latest => tasks.last;

  void Function() schedule(Duration delay, void Function() callback) {
    lastDelay = delay;
    final task = _FakeScheduledTask(callback);
    tasks.add(task);
    return task.cancel;
  }

  void fireLatest() => latest.fire();
}

final class _FakeScheduledTask {
  _FakeScheduledTask(this.callback);

  final void Function() callback;
  bool cancelled = false;

  void cancel() => cancelled = true;

  void fire() {
    if (!cancelled) callback();
  }

  void fireEvenIfCancelled() => callback();
}