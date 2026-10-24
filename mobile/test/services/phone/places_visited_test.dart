import 'package:echo_app/models/place.dart';
import 'package:echo_app/services/api/places_api.dart';
import 'package:echo_app/services/app/network_policy.dart';
import 'package:echo_app/services/phone/places_visited.dart';
import 'package:echo_app/services/phone/visit_sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

RecordedVisit stay(String key, {bool open = false, String? address = 'Via Roma 12'}) =>
    RecordedVisit(
      key: key,
      arrivedAt: DateTime.utc(2026, 10, 24, 8),
      leftAt: open ? null : DateTime.utc(2026, 10, 24, 9),
      latitude: 45.46,
      longitude: 9.19,
      address: address,
    );

void main() {
  late FakeSource source;
  late FakePlacesApi api;
  late FakeNetwork network;
  late NetworkPolicy policy;
  late SharedPreferences preferences;

  Future<PlacesVisitedService> service({Map<String, Object> stored = const {}}) async {
    SharedPreferences.setMockInitialValues(stored);
    preferences = await SharedPreferences.getInstance();
    return PlacesVisitedService(
      source: source,
      api: api,
      preferences: preferences,
      networkAccess: network,
      networkPolicy: policy,
      geocode: (lat, lng) async => 'Corso Como 15, Milano',
    );
  }

  setUp(() {
    source = FakeSource();
    api = FakePlacesApi();
    network = FakeNetwork({NetworkType.wifi});
    policy = NetworkPolicy();
  });

  test('off by default: nothing starts', () async {
    final places = await service();

    await places.resume();

    expect(places.isOn, isFalse);
    expect(source.started, isFalse);
  });

  test('turning on without Always stays off', () async {
    source.afterRequest = VisitAccess.whileInUse;
    final places = await service();

    expect(await places.turnOn(), VisitAccess.whileInUse);

    expect(places.isOn, isFalse);
    expect(source.started, isFalse);
    expect(source.requested, isTrue);
  });

  test('turned on, the stays go up and leave the phone', () async {
    final places = await service();

    expect(await places.turnOn(), VisitAccess.always);
    expect(places.on.value, isTrue);
    source.emit([stay('a', open: true), stay('b', address: null)]);
    source.emit([stay('a')]);
    await places.idle();

    final sent = api.sent.expand((batch) => batch).toList();
    expect(sent.map((v) => v.key), containsAll(['a', 'b']));
    expect(sent.firstWhere((v) => v.key == 'b').address, 'Corso Como 15, Milano');
    expect(sent.lastWhere((v) => v.key == 'a').leftAt, isNotNull);
    expect(api.sources.toSet(), {'fake'});
    expect(places.waiting, 0);
  });

  test('Wi-Fi only on mobile data keeps them for later', () async {
    network.types = {NetworkType.mobile};
    policy.setAllowCellular(false);
    final places = await service();
    await places.turnOn();

    source.emit([stay('a')]);
    await places.idle();
    expect(api.sent, isEmpty);
    expect(places.waiting, 1);

    network.types = {NetworkType.wifi};
    await places.flush();
    expect(api.sent.single.single.key, 'a');
    expect(places.waiting, 0);
  });

  test('a failed upload keeps them', () async {
    api.fail = true;
    final places = await service();
    await places.turnOn();

    source.emit([stay('a')]);
    await places.idle();

    expect(places.waiting, 1);
    api.fail = false;
    await places.flush();
    expect(places.waiting, 0);
  });

  test('turning off drops the outbox and stops the source', () async {
    network.types = {NetworkType.none};
    final places = await service();
    await places.turnOn();
    source.emit([stay('a')]);
    await places.idle();
    expect(places.waiting, 1);

    await places.turnOff();
    source.emit([stay('late')]);
    network.types = {NetworkType.wifi};
    await places.flush();
    await places.idle();

    expect(places.isOn, isFalse);
    expect(source.started, isFalse);
    expect(places.waiting, 0);
    expect(api.sent, isEmpty);
  });

  test('on after a restart, it starts again and sends what was waiting', () async {
    final places = await service(stored: {
      PlacesVisitedService.onKey: true,
      PlacesVisitedService.outboxKey: '[${_json(stay('kept'))}]',
    });

    await places.resume();

    expect(source.started, isTrue);
    expect(api.sent.single.single.key, 'kept');
  });
}

String _json(RecordedVisit visit) =>
    '{"key":"${visit.key}","arrived_at":"${visit.arrivedAt.toIso8601String()}",'
    '"left_at":"${visit.leftAt!.toIso8601String()}","latitude":45.46,"longitude":9.19}';

final class FakeSource implements VisitSource {
  VisitAccess current = VisitAccess.notAsked;
  VisitAccess afterRequest = VisitAccess.always;
  bool started = false;
  bool requested = false;
  void Function(List<RecordedVisit>)? _onVisits;

  void emit(List<RecordedVisit> visits) => _onVisits?.call(visits);

  @override
  String get name => 'fake';

  @override
  Future<VisitAccess> access() async => current;

  @override
  Future<VisitAccess> requestAlways() async {
    requested = true;
    return current = afterRequest;
  }

  @override
  Future<void> start(void Function(List<RecordedVisit>) onVisits) async {
    started = true;
    _onVisits = onVisits;
  }

  @override
  Future<void> stop() async {
    started = false;
    _onVisits = null;
  }
}

class FakePlacesApi implements PlacesApi {
  final sent = <List<RecordedVisit>>[];
  final sources = <String>[];
  bool fail = false;

  @override
  Future<void> postVisits(List<RecordedVisit> visits, {required String source}) async {
    if (fail) throw Exception('offline');
    sent.add(visits);
    sources.add(source);
  }

  @override
  Future<VisitPage> listVisits({DateTime? before}) async =>
      const VisitPage(visits: [], more: false);

  @override
  Future<void> deleteVisit(String id) async {}

  @override
  Future<void> deleteVisitDay(DateTime day) async {}

  @override
  Future<void> deleteAllVisits() async {}
}

final class FakeNetwork implements NetworkAccess {
  FakeNetwork(this.types);

  Set<NetworkType> types;

  @override
  Future<Set<NetworkType>> currentTypes() async => types;
}
