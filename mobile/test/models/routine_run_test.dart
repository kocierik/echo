import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/routine.dart';
import 'package:echo_app/models/routine_run.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _run([Map<String, dynamic> extra = const {}]) => {
      'id': 'r1',
      'routine_id': 'rt1',
      'instruction': 'dimmi se piove domani',
      'mode': 'only_if',
      'schedule_text': 'Every day at 07:00',
      'ran_at': '2026-10-28T06:00:00Z',
      'status': 'reported',
      'text': 'Domani piove dalle 15',
      'sources': [
        {'title': 'Meteo', 'url': 'https://meteo.it/milano'},
        {'title': 'No link', 'url': 'javascript:alert(1)'},
        {'title': 'Missing'},
      ],
      ...extra,
    };

void main() {
  test('a run reads its routine, local time, text and sources', () {
    final run = RoutineRun.fromJson(_run());

    expect(run.id, 'r1');
    expect(run.routineId, 'rt1');
    expect(run.instruction, 'dimmi se piove domani');
    expect(run.mode, 'only_if');
    expect(run.scheduleText, 'Every day at 07:00');
    expect(run.ranAt, DateTime.utc(2026, 10, 28, 6).toLocal());
    expect(run.ranAt.isUtc, isFalse);
    expect(run.status, 'reported');
    expect(run.text, 'Domani piove dalle 15');
    expect(run.hasText, isTrue);
    expect(run.sources.map((s) => s.title), ['Meteo', 'No link', 'Missing']);
    expect(run.sources.first.url, Uri.parse('https://meteo.it/milano'));
    expect(run.sources[1].url, isNull);
    expect(run.sources[2].url, isNull);
  });

  test('a quiet run has no text', () {
    final run = RoutineRun.fromJson(_run({'status': 'nothing', 'text': null, 'sources': null}));

    expect(run.hasText, isFalse);
    expect(run.sources, isEmpty);
  });

  test('a page knows where the next one starts', () {
    final page = RoutineRunPage.fromJson({
      'items': [_run()],
      'next_before': '2026-10-28T06:00:00Z',
    });
    final last = RoutineRunPage.fromJson(const {'items': <Object?>[], 'next_before': null});

    expect(page.items.single.id, 'r1');
    expect(page.nextBefore, DateTime.utc(2026, 10, 28, 6).toLocal());
    expect(last.nextBefore, isNull);
  });

  test('a routine without a mode is always; an old ok is reported', () {
    final routine = Routine.fromJson(const {
      'id': 'rt1',
      'instruction': 'meteo',
      'schedule_text': 'Every day at 07:00',
      'active': true,
      'next_run_at': '2026-10-29T06:00:00Z',
      'last_status': 'ok',
    });
    final newer = Routine.fromJson(const {
      'id': 'rt2',
      'instruction': 'nuove posizioni',
      'schedule_text': 'Every day at 09:00',
      'active': true,
      'next_run_at': '2026-10-29T08:00:00Z',
      'mode': 'only_new',
      'last_status': 'nothing',
    });

    expect(routine.mode, 'always');
    expect(routine.lastStatus, 'reported');
    expect(newer.mode, 'only_new');
    expect(newer.lastStatus, 'nothing');
    expect(newer.copyWith(active: false).mode, 'only_new');
  });

  test('each mode in words', () {
    expect(routineModeText('always'), 'Always tells you');
    expect(routineModeText('only_if'), 'Tells you only when its condition holds');
    expect(routineModeText('only_new'), 'Tells you only what is new');
    expect(routineModeText('other'), 'Always tells you');
  });

  test('voice updates bring new routine runs, none when the field is missing', () {
    final updates = VoiceUpdates.fromJson({
      'messages': <Object?>[],
      'routine_runs': [
        {
          'id': 'r1',
          'routine_id': 'rt1',
          'status': 'failed',
          'text': 'Non riuscito',
          'ran_at': '2026-10-28T06:00:00Z',
        },
      ],
      'now': '2026-10-28T06:01:00Z',
    });
    final older = VoiceUpdates.fromJson({
      'messages': <Object?>[],
      'now': '2026-10-28T06:01:00Z',
    });

    final run = updates.routineRuns.single;
    expect((run.id, run.routineId, run.status, run.text), ('r1', 'rt1', 'failed', 'Non riuscito'));
    expect(run.ranAt, DateTime.utc(2026, 10, 28, 6).toLocal());
    expect(older.routineRuns, isEmpty);
  });
}
