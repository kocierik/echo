import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../../models/place.dart';
import 'stay_detector.dart';

/// Whether the phone lets Echo notice visits: "Always" is needed (the phone is in a
/// pocket, Echo not on screen); "while in use" is not enough.
enum VisitAccess { always, whileInUse, denied, notAsked, off, unavailable }

/// Where the phone's stays come from: iOS's own visit detection, or on Android the
/// stays worked out from low-power positions. Nothing is read before [start] or after
/// [stop].
abstract interface class VisitSource {
  /// "ios" or "android", as the server keeps it.
  String get name;

  Future<VisitAccess> access();

  /// Asks for "Always" (first "while in use" when never asked); only while on screen.
  Future<VisitAccess> requestAlways();

  /// Starts noticing stays; [onVisits] gets each stay when it starts and when it ends.
  Future<void> start(void Function(List<RecordedVisit> visits) onVisits);

  /// Stops at once, and forgets the stay going on.
  Future<void> stop();
}

/// iOS: `CLLocationManager.startMonitoringVisits` in VisitRecorder.swift, over the
/// "echo/visits" channel. The recorder keeps the visits (with Apple's place name and the
/// address) until they are taken: iOS may wake Echo for a visit without its Flutter side.
final class IosVisitSource implements VisitSource {
  IosVisitSource({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('echo/visits');

  final MethodChannel _channel;
  void Function(List<RecordedVisit> visits)? _onVisits;

  @override
  String get name => 'ios';

  @override
  Future<VisitAccess> access() => _access('access');

  @override
  Future<VisitAccess> requestAlways() => _access('requestAlways');

  Future<VisitAccess> _access(String method) async {
    try {
      return _accessNamed(await _channel.invokeMethod<String>(method));
    } on MissingPluginException {
      return VisitAccess.unavailable;
    } on PlatformException {
      return VisitAccess.unavailable;
    }
  }

  static VisitAccess _accessNamed(String? name) => switch (name) {
        'always' => VisitAccess.always,
        'whileInUse' => VisitAccess.whileInUse,
        'denied' => VisitAccess.denied,
        'notAsked' => VisitAccess.notAsked,
        'off' => VisitAccess.off,
        _ => VisitAccess.unavailable,
      };

  @override
  Future<void> start(void Function(List<RecordedVisit> visits) onVisits) async {
    _onVisits = onVisits;
    // The recorder says "visits" when it has new ones
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'visits') await _take();
    });
    try {
      await _channel.invokeMethod<void>('start');
    } on MissingPluginException {
      return;
    }
    // Those noticed while Echo's Flutter side was not running
    await _take();
  }

  Future<void> _take() async {
    final onVisits = _onVisits;
    if (onVisits == null) return;
    try {
      final taken = await _channel.invokeMethod<List<Object?>>('take') ?? const [];
      final visits = taken.map(_visit).whereType<RecordedVisit>().toList();
      if (visits.isNotEmpty) onVisits(visits);
    } catch (error) {
      debugPrint('[Places] could not take the visits: $error');
    }
  }

  /// Times cross the channel as epoch milliseconds.
  static RecordedVisit? _visit(Object? item) {
    if (item is! Map) return null;
    final key = item['key'];
    final arrived = item['arrived'];
    final latitude = item['latitude'];
    final longitude = item['longitude'];
    if (key is! String || arrived is! int || latitude is! num || longitude is! num) {
      return null;
    }
    final left = item['left'];
    final accuracy = item['accuracy'];
    final name = item['name'];
    final address = item['address'];
    return RecordedVisit(
      key: key,
      arrivedAt: DateTime.fromMillisecondsSinceEpoch(arrived, isUtc: true),
      leftAt: left is int ? DateTime.fromMillisecondsSinceEpoch(left, isUtc: true) : null,
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      accuracyM: accuracy is num ? accuracy.toDouble() : null,
      name: name is String && name.trim().isNotEmpty ? name.trim() : null,
      address: address is String && address.trim().isNotEmpty ? address.trim() : null,
    );
  }

  @override
  Future<void> stop() async {
    _onVisits = null;
    _channel.setMethodCallHandler(null);
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      return;
    }
  }
}

/// The phone's location on Android, as the stays need it (geolocator; fakes in tests).
abstract interface class AndroidLocation {
  Future<VisitAccess> access();

  /// Asks for the location, then for "Allow all the time" (Android opens its settings).
  Future<VisitAccess> request();

  /// Positions every few minutes at low power, until the subscription is cancelled.
  Stream<Fix> fixes();
}

/// Where the stay going on is kept between restarts of the app.
abstract interface class StayStore {
  Map<String, Object?>? read();
  Future<void> write(Map<String, Object?>? state);
}

/// Android: no visit detection in the system, so the stays are worked out on the phone
/// ([StayDetector]) from positions at balanced power (Wi-Fi and cell, rarely GPS) every
/// few minutes. They come while the process lives, which EchoStatusService keeps while
/// a wearable is paired; then too only with "Allow all the time".
final class AndroidStaySource implements VisitSource {
  AndroidStaySource({required AndroidLocation location, required StayStore store})
      : _location = location,
        _store = store;

  final AndroidLocation _location;
  final StayStore _store;
  StreamSubscription<Fix>? _subscription;

  @override
  String get name => 'android';

  @override
  Future<VisitAccess> access() => _location.access();

  @override
  Future<VisitAccess> requestAlways() => _location.request();

  @override
  Future<void> start(void Function(List<RecordedVisit> visits) onVisits) async {
    if (_subscription != null) return;
    final saved = _store.read();
    final detector = saved == null ? StayDetector() : StayDetector.fromJson(saved);
    _subscription = _location.fixes().listen(
      (fix) {
        final visits = detector.add(fix);
        unawaited(_store.write(detector.toJson()));
        if (visits.isNotEmpty) onVisits(visits);
      },
      onError: (Object error) => debugPrint('[Places] no position: $error'),
    );
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _store.write(null);
  }
}

/// [AndroidLocation] through geolocator: the fused provider at balanced power.
final class GeolocatorAndroidLocation implements AndroidLocation {
  const GeolocatorAndroidLocation();

  /// Often enough to notice a 10-minute stay, rarely enough to cost little.
  static const interval = Duration(minutes: 3);

  @override
  Future<VisitAccess> access() async {
    if (!await Geolocator.isLocationServiceEnabled()) return VisitAccess.off;
    return _access(await Geolocator.checkPermission());
  }

  @override
  Future<VisitAccess> request() async {
    var access = _access(await Geolocator.requestPermission());
    // The second request asks for "Allow all the time" (geolocator adds the background
    // permission once "while in use" is given)
    if (access == VisitAccess.whileInUse) {
      access = _access(await Geolocator.requestPermission());
    }
    return access;
  }

  static VisitAccess _access(LocationPermission permission) => switch (permission) {
        LocationPermission.always => VisitAccess.always,
        LocationPermission.whileInUse => VisitAccess.whileInUse,
        LocationPermission.denied => VisitAccess.notAsked,
        LocationPermission.deniedForever => VisitAccess.denied,
        LocationPermission.unableToDetermine => VisitAccess.unavailable,
      };

  @override
  Stream<Fix> fixes() => Geolocator.getPositionStream(
        locationSettings: AndroidSettings(
          // PRIORITY_BALANCED_POWER_ACCURACY: about 100 m, from Wi-Fi and cells
          accuracy: LocationAccuracy.medium,
          intervalDuration: interval,
          distanceFilter: 0,
        ),
      ).map((position) => Fix(
            latitude: position.latitude,
            longitude: position.longitude,
            accuracyM: position.accuracy,
            at: position.timestamp.toUtc(),
          ));
}
