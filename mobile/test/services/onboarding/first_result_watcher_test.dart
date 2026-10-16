import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/chat_session.dart';
import 'package:echo_app/models/today_insights.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/services/chat/voice_updates_service.dart';
import 'package:echo_app/services/onboarding/first_result_watcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final opened = DateTime.utc(2026, 10, 16, 9);

  testWidgets('shows what was heard, then the answer', (tester) async {
    final api = _FakeVoiceApi(serverNow: opened);
    final watcher = _watcher(api, () => opened);
    addTearDown(watcher.dispose);

    await watcher.start();
    api.working = [_working('Echo, remind me to call Giulia on Friday at six')];
    await tester.pump(const Duration(seconds: 2));
    expect(
        watcher.value.heard, 'Echo, remind me to call Giulia on Friday at six');
    expect(watcher.value.answer, isNull);

    api.working = [];
    api.answers = [
      _answer('Done: call Giulia, Friday at 18:00.',
          opened.add(const Duration(seconds: 5)))
    ];
    await tester.pump(const Duration(seconds: 2));
    expect(watcher.value.answer, 'Done: call Giulia, Friday at 18:00.');
    expect(watcher.value.gaveUp, isFalse);

    // Answered: no more checks
    final calls = api.calls;
    await tester.pump(const Duration(seconds: 10));
    expect(api.calls, calls);
  });

  testWidgets('the 30 seconds start when Echo hears the request',
      (tester) async {
    final api = _FakeVoiceApi(serverNow: opened);
    var now = opened;
    final watcher = _watcher(api, () => now);
    Future<void> wait(int seconds) async {
      for (var s = 0; s < seconds; s += 2) {
        now = now.add(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 2));
      }
    }

    await watcher.start();
    // Reading the screen, picking up Echo: no clock running yet
    await wait(40);
    expect(watcher.value.gaveUp, isFalse);

    api.working = [_working('Echo, remind me to call Giulia')];
    await wait(28);
    expect(watcher.value.heard, 'Echo, remind me to call Giulia');
    expect(watcher.value.gaveUp, isFalse);

    await wait(4);
    expect(watcher.value.gaveUp, isTrue);
    expect(watcher.value.heard, 'Echo, remind me to call Giulia');
    // Still watching for a late answer: stop it before the test ends
    watcher.dispose();
  });

  testWidgets('a late answer still replaces the fallback', (tester) async {
    final api = _FakeVoiceApi(serverNow: opened);
    var now = opened;
    final watcher = _watcher(api, () => now);
    addTearDown(watcher.dispose);

    await watcher.start();
    api.working = [_working('Echo, remind me to call Giulia')];
    for (var s = 0; s < 34; s += 2) {
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
    }
    expect(watcher.value.gaveUp, isTrue);

    api.answers = [
      _answer('Done: call Giulia.', opened.add(const Duration(seconds: 40)))
    ];
    now = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));

    expect(watcher.value.answer, 'Done: call Giulia.');
    expect(watcher.value.gaveUp, isFalse);
  });

  testWidgets('ignores answers from before the screen opened', (tester) async {
    final api = _FakeVoiceApi(serverNow: opened)
      ..answers = [
        _answer('An old answer', opened.subtract(const Duration(hours: 1)))
      ];
    final watcher = _watcher(api, () => opened);

    await watcher.start();
    await tester.pump(const Duration(seconds: 2));

    expect(api.sinces.skip(1), everyElement(opened));
    expect(watcher.value.answer, isNull);
    // Still watching: stop it before the test ends
    watcher.dispose();
  });

  testWidgets('a failing check keeps trying', (tester) async {
    final api = _FakeVoiceApi(serverNow: opened)..failing = true;
    final watcher = _watcher(api, () => opened);
    addTearDown(watcher.dispose);

    await watcher.start();
    await tester.pump(const Duration(seconds: 2));
    api
      ..failing = false
      ..answers = [_answer('Got it.', opened.add(const Duration(seconds: 3)))];
    await tester.pump(const Duration(seconds: 2));

    expect(watcher.value.answer, 'Got it.');
  });
}

FirstResultWatcher _watcher(_FakeVoiceApi api, DateTime Function() clock) {
  return FirstResultWatcher(working: api, updates: api, clock: clock);
}

WorkingItem _working(String text) => WorkingItem(
      key: 'voice:1',
      kind: 'voice',
      text: text,
      since: DateTime.utc(2026, 10, 16, 9),
    );

ChatSessionMessage _answer(String text, DateTime at) =>
    ChatSessionMessage(role: 'assistant', content: text, timestamp: at);

final class _FakeVoiceApi implements VoiceWorkingApi, VoiceUpdatesApi {
  _FakeVoiceApi({required this.serverNow});

  final DateTime serverNow;
  List<WorkingItem> working = [];
  List<ChatSessionMessage> answers = [];
  bool failing = false;
  final sinces = <DateTime?>[];
  int calls = 0;

  @override
  Future<List<WorkingItem>> getVoiceWorking() async {
    calls++;
    if (failing) throw Exception('offline');
    return List.of(working);
  }

  @override
  Future<VoiceUpdates> getVoiceUpdates(DateTime? since) async {
    calls++;
    sinces.add(since);
    if (failing) throw Exception('offline');
    // Like the server: only what came after `since`
    return VoiceUpdates(
      messages: [
        for (final m in answers)
          if (since == null || m.timestamp!.isAfter(since)) m,
      ],
      now: serverNow,
    );
  }
}
