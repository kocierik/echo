import 'dart:async';

import 'package:echo_app/models/place.dart';
import 'package:echo_app/services/phone/stay_detector.dart';
import 'package:echo_app/services/phone/visit_sources.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('echo/visits');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('iOS', () {
    late List<String> calls;
    late List<Object?> pending;

    setUp(() {
      calls = [];
      pending = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'access' => 'whileInUse',
          'requestAlways' => 'always',
          'take' => () {
              final taken = List<Object?>.of(pending);
              pending.clear();
              return taken;
            }(),
          _ => null,
        };
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('asks for Always and takes the visits the recorder kept', () async {
      final source = IosVisitSource();
      pending.add({
        'key': 'ios:1760730900',
        'arrived': DateTime.utc(2026, 10, 17, 19, 55).millisecondsSinceEpoch,
        'left': DateTime.utc(2026, 10, 17, 23, 10).millisecondsSinceEpoch,
        'latitude': 45.46,
        'longitude': 9.19,
        'accuracy': 35.0,
        'name': 'Pizzeria Da Gino',
        'address': 'Via Garibaldi 5, Milano',
      });
      pending.add({'key': 'broken'});
      final received = <RecordedVisit>[];

      expect(await source.access(), VisitAccess.whileInUse);
      expect(await source.requestAlways(), VisitAccess.always);
      await source.start(received.addAll);

      expect(received.single.name, 'Pizzeria Da Gino');
      expect(received.single.leftAt, DateTime.utc(2026, 10, 17, 23, 10));

      // A new visit while running: the recorder says so, the source takes it
      pending.add({
        'key': 'ios:2',
        'arrived': DateTime.utc(2026, 10, 18, 9).millisecondsSinceEpoch,
        'latitude': 45.0,
        'longitude': 9.0,
      });
      await messenger.handlePlatformMessage(
        'echo/visits',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('visits')),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);

      expect(received.last.key, 'ios:2');
      expect(received.last.leftAt, isNull);
      await source.stop();
      expect(calls, ['access', 'requestAlways', 'start', 'take', 'take', 'stop']);
    });
  });

  group('Android', () {
    test('stays come from the positions, and stopping forgets the stay going on', () async {
      final location = _FakeLocation();
      final store = _MemoryStore();
      final source = AndroidStaySource(location: location, store: store);
      final received = <RecordedVisit>[];
      final start = DateTime.utc(2026, 10, 24, 8);

      await source.start(received.addAll);
      for (final minutes in [0, 4, 8, 12]) {
        location.fixes$.add(Fix(latitude: 45.46, longitude: 9.19, at: start.add(Duration(minutes: minutes))));
      }
      await Future<void>.delayed(Duration.zero);

      expect(received.single.leftAt, isNull);
      expect(store.state, isNotNull);
      await source.stop();
      expect(location.fixes$.hasListener, isFalse);
      expect(store.state, isNull);
    });
  });
}

final class _FakeLocation implements AndroidLocation {
  final fixes$ = StreamController<Fix>.broadcast();

  @override
  Future<VisitAccess> access() async => VisitAccess.always;

  @override
  Future<VisitAccess> request() async => VisitAccess.always;

  @override
  Stream<Fix> fixes() => fixes$.stream;
}

final class _MemoryStore implements StayStore {
  Map<String, Object?>? state;

  @override
  Map<String, Object?>? read() => state;

  @override
  Future<void> write(Map<String, Object?>? value) async => state = value;
}
