import 'dart:async';

import 'package:echo_app/models/action_models.dart';
import 'package:echo_app/models/chat_session.dart';
import 'package:echo_app/services/app/notification_service.dart';
import 'package:echo_app/services/chat/voice_updates_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 13, 12);
  late _FakeApi api;
  late _FakePort port;
  late SharedPreferences prefs;
  late VoiceUpdatesService service;

  Future<void> setUpService([Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(initial);
    prefs = await SharedPreferences.getInstance();
    api = _FakeApi();
    port = _FakePort();
    service = VoiceUpdatesService(api, NotificationService(port), prefs);
  }

  ChatSessionMessage message(String content, DateTime at,
          {String session = 's1'}) =>
      ChatSessionMessage(
        role: 'assistant',
        content: content,
        timestamp: at,
        sessionId: session,
      );

  test('new answers tell the thread to reload, once per check', () async {
    await setUpService({
      VoiceUpdatesService.lastSeenKey: t0.toIso8601String(),
    });
    var changed = 0;
    service = VoiceUpdatesService(api, NotificationService(port), prefs,
        onNewMessages: () => changed++);
    api.response = VoiceUpdates(
      messages: [
        message('one', t0.add(const Duration(minutes: 1))),
        message('two', t0.add(const Duration(minutes: 2))),
      ],
      now: t0.add(const Duration(minutes: 3)),
    );

    await service.check();
    await service.check(); // the same answers again: nothing new
    expect(changed, 1);
  });

  test('first check only stores now and shows nothing', () async {
    await setUpService();
    api.response = VoiceUpdates(messages: [message('old', t0)], now: t0);

    await service.check();

    expect(api.sinceArgs, [null]);
    expect(port.shown, isEmpty);
    expect(prefs.getString(VoiceUpdatesService.lastSeenKey),
        t0.toIso8601String());
  });

  test('new messages notify once each, truncated, polling with 60s overlap',
      () async {
    await setUpService({
      VoiceUpdatesService.lastSeenKey: t0.toIso8601String(),
    });
    final later = t0.add(const Duration(minutes: 5));
    api.response = VoiceUpdates(
      messages: [
        message('short answer', t0.add(const Duration(minutes: 1))),
        message('x' * 130, t0.add(const Duration(minutes: 2))),
      ],
      now: later,
    );

    await service.check();

    expect(api.sinceArgs.single, t0.subtract(const Duration(seconds: 60)));
    expect(port.shown, hasLength(2));
    expect(port.shown[0].title, 'Echo');
    expect(port.shown[0].body, 'short answer');
    expect(port.shown[0].payload, 'voice:s1');
    expect(port.shown[1].body, '${'x' * 120}…');
    expect(port.shown[0].id, isNot(port.shown[1].id));
    for (final n in port.shown) {
      expect(n.id, inInclusiveRange(200, 249));
    }
    expect(prefs.getString(VoiceUpdatesService.lastSeenKey),
        later.toIso8601String());
  });

  test('messages seen again through the overlap window are not repeated',
      () async {
    await setUpService({
      VoiceUpdatesService.lastSeenKey: t0.toIso8601String(),
    });
    final answer = message('hello', t0.add(const Duration(seconds: 30)));
    api.response = VoiceUpdates(
      messages: [answer],
      now: t0.add(const Duration(minutes: 1)),
    );
    await service.check();
    api.response = VoiceUpdates(
      messages: [answer],
      now: t0.add(const Duration(minutes: 2)),
    );
    await service.check();

    expect(port.shown, hasLength(1));
  });

  test('seen keys are capped at 50', () async {
    await setUpService({
      VoiceUpdatesService.lastSeenKey: t0.toIso8601String(),
    });
    api.response = VoiceUpdates(
      messages: [
        for (var i = 0; i < 60; i++)
          message('m$i', t0.add(Duration(seconds: i + 1))),
      ],
      now: t0.add(const Duration(hours: 1)),
    );

    await service.check();

    expect(port.shown, hasLength(60));
    expect(prefs.getStringList(VoiceUpdatesService.seenKeysKey),
        hasLength(50));
  });

  test('failures are swallowed and lastSeen is not advanced', () async {
    await setUpService({
      VoiceUpdatesService.lastSeenKey: t0.toIso8601String(),
    });
    api.error = StateError('offline');

    await service.check();

    expect(port.shown, isEmpty);
    expect(prefs.getString(VoiceUpdatesService.lastSeenKey),
        t0.toIso8601String());
  });

  test('concurrent checks make one request', () async {
    await setUpService({
      VoiceUpdatesService.lastSeenKey: t0.toIso8601String(),
    });
    final gate = Completer<void>();
    api.gate = gate.future;
    api.response = VoiceUpdates(messages: const [], now: t0);

    final a = service.check();
    final b = service.check();
    gate.complete();
    await Future.wait([a, b]);

    expect(api.sinceArgs, hasLength(1));
  });
}

final class _FakeApi implements VoiceUpdatesApi {
  final List<DateTime?> sinceArgs = [];
  VoiceUpdates? response;
  Object? error;
  Future<void>? gate;

  @override
  Future<VoiceUpdates> getVoiceUpdates(DateTime? since) async {
    sinceArgs.add(since);
    await gate;
    final e = error;
    if (e != null) throw e;
    return response!;
  }
}

final class _Shown {
  _Shown(this.id, this.title, this.body, this.payload);

  final int id;
  final String title;
  final String body;
  final String? payload;
}

final class _FakePort implements NotificationPort {
  final List<_Shown> shown = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required Duration delay,
    String? payload,
  }) async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    shown.add(_Shown(id, title, body, payload));
  }
}
