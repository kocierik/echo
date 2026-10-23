import 'package:echo_app/models/device_command.dart';
import 'package:echo_app/models/saved.dart';
import 'package:echo_app/services/api/device_api.dart';
import 'package:echo_app/services/api/saved_api.dart';
import 'package:echo_app/services/phone/phone_location.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakeReader reader;
  late _FakeServer server;
  late bool foreground;
  late int notified;
  late DateTime now;
  late PhoneLocationService service;

  setUp(() {
    reader = _FakeReader();
    server = _FakeServer();
    foreground = true;
    notified = 0;
    now = DateTime(2026, 10, 23, 9, 40);
    service = PhoneLocationService(
      reader: reader,
      commands: server,
      saved: server,
      inForeground: () => foreground,
      notifyOpen: () async => notified++,
      clock: () => now,
    );
  });

  const command = GetLocationCommand(id: 'c1', itemId: 'car');

  test('the first save with a place asks for the permission, then sends the place', () async {
    reader.access_ = LocationAccess.notAsked;

    await service.handle(command);

    expect(reader.requests, 1);
    expect(server.results['c1'], {
      'ok': true,
      'data': {
        'latitude': 45.46,
        'longitude': 9.19,
        'accuracy_m': 8.0,
        'address': 'Via Roma 12, Milano',
      },
    });
  });

  test('allowed already: never asked again', () async {
    await service.handle(command);

    expect(reader.requests, 0);
    expect(server.results['c1']!['ok'], isTrue);
  });

  test('refused, or no location on the phone: said so', () async {
    reader.access_ = LocationAccess.denied;
    await service.handle(command);
    expect(server.results['c1'], {'ok': false, 'error': 'denied'});

    reader.access_ = LocationAccess.off;
    await service.handle(const GetLocationCommand(id: 'c2'));
    expect(server.results['c2'], {'ok': false, 'error': 'unavailable'});
  });

  test('without an address the coordinates still go', () async {
    reader.addressOf = null;

    await service.handle(command);

    expect((server.results['c1']!['data'] as Map)['address'], isNull);
  });

  test('in the background it asks the user to open Echo, then sends the place', () async {
    foreground = false;

    await service.handle(command);

    expect(server.results['c1'], {'ok': false, 'error': 'background'});
    expect(notified, 1);
    expect(reader.reads, 0);

    foreground = true;
    now = now.add(const Duration(minutes: 2));
    await service.onResumed();

    expect(server.places['car']!.address, 'Via Roma 12, Milano');
    // Once only
    await service.onResumed();
    expect(server.placeCalls, 1);
  });

  test('opened too late, the place is no longer the one asked for', () async {
    foreground = false;
    await service.handle(command);

    foreground = true;
    now = now.add(const Duration(minutes: 6));
    await service.onResumed();

    expect(server.places, isEmpty);
  });

  test('the distance only with the permission already given', () async {
    const car = SavedPlace(latitude: 45.47, longitude: 9.19);

    expect(await service.distanceTo(car), 1000);

    reader.access_ = LocationAccess.notAsked;
    expect(await service.distanceTo(car), isNull);
    expect(reader.requests, 0);
  });
}

final class _FakeReader implements LocationReader {
  LocationAccess access_ = LocationAccess.granted;
  String? addressOf = 'Via Roma 12, Milano';
  int requests = 0;
  int reads = 0;

  @override
  Future<LocationAccess> access() async => access_;

  @override
  Future<LocationAccess> request() async {
    requests++;
    return access_ = LocationAccess.granted;
  }

  @override
  Future<ReadPlace?> current() async {
    reads++;
    return const ReadPlace(latitude: 45.46, longitude: 9.19, accuracyM: 8);
  }

  @override
  Future<ReadPlace?> lastKnown() async =>
      const ReadPlace(latitude: 45.46, longitude: 9.19, accuracyM: 20);

  @override
  Future<String?> address(double latitude, double longitude) async => addressOf;

  @override
  double distance(double fromLat, double fromLng, double toLat, double toLng) => 1000;
}

final class _FakeServer implements DeviceCommandsApi, SavedApi {
  final results = <String, Map<String, Object?>>{};
  final places = <String, SavedPlace>{};
  int placeCalls = 0;

  @override
  Future<void> sendCommandResult(String commandId, Map<String, Object?> result) async {
    results[commandId] = result;
  }

  @override
  Future<SavedItem> putSavedPlace(String id, SavedPlace place) async {
    placeCalls++;
    places[id] = place;
    return SavedItem(id: id, listId: 'l', list: 'Your car', title: 'Car', savedAt: DateTime(2026));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
