import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/place.dart';
import '../api/places_api.dart';
import '../app/network_policy.dart';
import 'visit_sources.dart';

/// Profile → Places visited: off by default. On, the phone's stays (where the user
/// stayed 10 minutes or more) go to the server, so Echo can say where they were and
/// where a conversation happened.
///
/// Nothing records unless it is on and the phone allows "Always"; turning it off stops
/// the source at once and drops the stays not sent yet. Stays wait in an outbox on the
/// phone and go up in batches, like segments: on any network unless the user chose
/// Wi-Fi only.
final class PlacesVisitedService {
  PlacesVisitedService({
    required VisitSource source,
    required PlacesApi api,
    required SharedPreferences preferences,
    required NetworkAccess networkAccess,
    required NetworkPolicy networkPolicy,
    Future<String?> Function(double latitude, double longitude)? geocode,
  })  : _source = source,
        _api = api,
        _preferences = preferences,
        _networkAccess = networkAccess,
        _networkPolicy = networkPolicy,
        _geocode = geocode,
        _on = ValueNotifier(preferences.getBool(onKey) ?? false);

  static const onKey = 'echo_places_visited';
  static const outboxKey = 'echo_places_outbox';

  /// Stays sent in one request.
  static const batchSize = 50;

  final VisitSource _source;
  final PlacesApi _api;
  final SharedPreferences _preferences;
  final NetworkAccess _networkAccess;
  final NetworkPolicy _networkPolicy;
  final Future<String?> Function(double latitude, double longitude)? _geocode;
  final ValueNotifier<bool> _on;

  /// One piece of work at a time: new stays, uploads.
  Future<void> _work = Future.value();

  bool get isOn => _on.value;

  /// For Profile's row and the screen.
  ValueListenable<bool> get on => _on;

  /// Stays not sent yet.
  int get waiting => _outbox().length;

  /// "ios" or "android".
  String get platform => _source.name;

  Future<VisitAccess> access() => _source.access();

  /// At start-up: when on, starts noticing stays again and sends what waits.
  Future<void> resume() async {
    if (!isOn) return;
    await _source.start(_received);
    await flush();
  }

  /// Asks for "Always" when needed; on only with it. Returns the phone's answer.
  Future<VisitAccess> turnOn() async {
    var access = await _source.access();
    if (access != VisitAccess.always) access = await _source.requestAlways();
    if (access != VisitAccess.always) return access;
    await _preferences.setBool(onKey, true);
    _on.value = true;
    await _source.start(_received);
    return access;
  }

  /// Stops at once; what was not sent is dropped (deleting what the server kept is a
  /// separate choice, PlacesApi.deleteAllVisits).
  Future<void> turnOff() async {
    _on.value = false;
    await _preferences.setBool(onKey, false);
    await _source.stop();
    await _preferences.remove(outboxKey);
  }

  /// Sends what waits, when the network and the user's choice allow it. Never throws.
  Future<void> flush() => _enqueue(_send);

  /// Completes when the stays received so far are handled (tests).
  @visibleForTesting
  Future<void> idle() => _work;

  void _received(List<RecordedVisit> visits) {
    if (!isOn) return;
    unawaited(_enqueue(() async {
      await _keep(visits);
      await _send();
    }));
  }

  Future<void> _enqueue(Future<void> Function() task) {
    final next = _work.then((_) async {
      try {
        await task();
      } catch (error) {
        debugPrint('[Places] $error');
      }
    });
    _work = next;
    return next;
  }

  Future<void> _keep(List<RecordedVisit> visits) async {
    final outbox = {for (final visit in _outbox()) visit.key: visit};
    for (var visit in visits) {
      final earlier = outbox[visit.key];
      if (visit.address == null && visit.name == null) {
        final address = earlier?.address ?? await _addressOf(visit);
        if (address != null) visit = visit.copyWith(address: address);
      }
      outbox[visit.key] = visit;
    }
    // Turned off while the address was looked up
    if (!isOn) return;
    await _save(outbox.values.toList());
  }

  Future<String?> _addressOf(RecordedVisit visit) async {
    final geocode = _geocode;
    if (geocode == null) return null;
    try {
      return await geocode(visit.latitude, visit.longitude);
    } catch (error) {
      debugPrint('[Places] no address: $error');
      return null;
    }
  }

  Future<void> _send() async {
    if (!isOn) return;
    var outbox = _outbox();
    if (outbox.isEmpty) return;
    if (!_networkPolicy.canUpload(await _networkAccess.currentTypes())) return;
    while (outbox.isNotEmpty && isOn) {
      final batch = outbox.take(batchSize).toList();
      await _api.postVisits(batch, source: _source.name);
      final sent = {for (final visit in batch) visit.key: jsonEncode(visit.toJson())};
      // A stay that changed meanwhile (it ended) stays to be sent again
      outbox = [
        for (final visit in _outbox())
          if (sent[visit.key] != jsonEncode(visit.toJson())) visit,
      ];
      await _save(outbox);
    }
  }

  List<RecordedVisit> _outbox() {
    final raw = _preferences.getString(outboxKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map(RecordedVisit.tryParse)
          .whereType<RecordedVisit>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<RecordedVisit> visits) async {
    if (visits.isEmpty) {
      await _preferences.remove(outboxKey);
    } else {
      await _preferences.setString(
        outboxKey,
        jsonEncode([for (final visit in visits) visit.toJson()]),
      );
    }
  }

  void dispose() => _on.dispose();
}

/// The Android stay going on, in the app's preferences.
final class PreferencesStayStore implements StayStore {
  PreferencesStayStore(this._preferences);

  static const key = 'echo_places_stay';
  final SharedPreferences _preferences;

  @override
  Map<String, Object?>? read() {
    final raw = _preferences.getString(key);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(Map<String, Object?>? state) async {
    if (state == null) {
      await _preferences.remove(key);
    } else {
      await _preferences.setString(key, jsonEncode(state));
    }
  }
}
