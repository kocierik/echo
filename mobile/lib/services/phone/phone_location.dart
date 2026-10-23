import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import '../../models/device_command.dart';
import '../../models/saved.dart';
import '../api/device_api.dart';
import '../api/saved_api.dart';

/// Whether Echo may read where the phone is: allowed, refused, never asked, or the
/// phone's location turned off.
enum LocationAccess { granted, denied, notAsked, off }

/// A position the phone read.
@immutable
final class ReadPlace {
  const ReadPlace({required this.latitude, required this.longitude, this.accuracyM});

  final double latitude;
  final double longitude;
  final double? accuracyM;
}

/// The phone's location as Echo uses it (geolocator and geocoding; fakes in tests).
abstract interface class LocationReader {
  Future<LocationAccess> access();

  /// Asks the user (the system's dialog); only while Echo is on screen.
  Future<LocationAccess> request();
  Future<ReadPlace?> current();

  /// The last position the phone knows, without reading a new one.
  Future<ReadPlace?> lastKnown();

  /// "Via Roma 12, Milano", from the phone's geocoder.
  Future<String?> address(double latitude, double longitude);

  /// Metres between two points.
  double distance(double fromLat, double fromLng, double toLat, double toLng);
}

/// Where the phone is, for a thing being saved with its place ("Echo, remember where I
/// parked"): the server asks with a `get_location` command, the place goes back as the
/// command's result. Nothing reads the position otherwise, and nothing keeps it here.
///
/// The permission ("while using the app") is asked the first time a place is saved,
/// never at start-up. In the background neither iOS nor Android give a position to such
/// an app: the user is asked to open Echo, and the place goes to the thing once Echo is
/// on screen, if that is soon enough to still be the same place.
final class PhoneLocationService {
  PhoneLocationService({
    required LocationReader reader,
    required DeviceCommandsApi commands,
    required SavedApi saved,
    required bool Function() inForeground,
    required Future<void> Function() notifyOpen,
    DateTime Function()? clock,
  })  : _reader = reader,
        _commands = commands,
        _saved = saved,
        _inForeground = inForeground,
        _notifyOpen = notifyOpen,
        _clock = clock ?? DateTime.now;

  /// Opened later than this, the phone may no longer be where the thing is.
  static const pendingFor = Duration(minutes: 5);

  final LocationReader _reader;
  final DeviceCommandsApi _commands;
  final SavedApi _saved;
  final bool Function() _inForeground;
  final Future<void> Function() _notifyOpen;
  final DateTime Function() _clock;

  /// The thing waiting for its place, and since when.
  (String, DateTime)? _pending;

  /// Reads the place for [command] and posts it. Never throws.
  Future<void> handle(GetLocationCommand command) async {
    Map<String, Object?> result;
    try {
      result = await _answer(command);
    } catch (error) {
      debugPrint('[Location] could not read the place: $error');
      result = _error('unavailable');
    }
    try {
      await _commands.sendCommandResult(command.id, result);
    } catch (error) {
      // The thing is saved without its place, and Echo says so
      debugPrint('[Location] could not send the place: $error');
    }
  }

  Future<Map<String, Object?>> _answer(GetLocationCommand command) async {
    if (!_inForeground()) {
      final itemId = command.itemId;
      if (itemId != null) _pending = (itemId, _clock());
      await _notifyOpen();
      return _error('background');
    }
    final (place, error) = await _read();
    if (place == null) return _error(error!);
    return {'ok': true, 'data': place.toJson()};
  }

  /// The place now, asking for the permission when it was never asked.
  Future<(SavedPlace?, String?)> _read() async {
    var access = await _reader.access();
    if (access == LocationAccess.notAsked) access = await _reader.request();
    if (access == LocationAccess.off) return (null, 'unavailable');
    if (access != LocationAccess.granted) return (null, 'denied');
    final position = await _reader.current();
    if (position == null) return (null, 'unavailable');
    String? address;
    try {
      address = await _reader.address(position.latitude, position.longitude);
    } catch (error) {
      debugPrint('[Location] no address: $error');
    }
    return (
      SavedPlace(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyM: position.accuracyM,
        address: address,
      ),
      null,
    );
  }

  /// Echo is on screen again: the place of a thing saved while it was in the background.
  /// Never throws.
  Future<void> onResumed() async {
    final pending = _pending;
    if (pending == null || !_inForeground()) return;
    _pending = null;
    final (itemId, since) = pending;
    if (_clock().difference(since) > pendingFor) return;
    try {
      final (place, _) = await _read();
      if (place != null) await _saved.putSavedPlace(itemId, place);
    } catch (error) {
      debugPrint('[Location] could not add the place later: $error');
    }
  }

  /// How far the phone is from [place], in metres: only with the permission already
  /// given (never asked for this), from the last position the phone knows. The position
  /// stays on the phone.
  Future<double?> distanceTo(SavedPlace place) async {
    try {
      if (await _reader.access() != LocationAccess.granted) return null;
      final here = await _reader.lastKnown();
      if (here == null) return null;
      return _reader.distance(here.latitude, here.longitude, place.latitude, place.longitude);
    } catch (_) {
      return null;
    }
  }

  static Map<String, Object?> _error(String reason) => {'ok': false, 'error': reason};
}

/// "650 m away", "1.2 km away".
String distanceLabel(double metres) {
  if (metres < 1000) return '${(metres / 10).round() * 10} m away';
  return '${(metres / 1000).toStringAsFixed(1)} km away';
}

/// The phone's location through geolocator, and its address through geocoding.
final class GeolocatorReader implements LocationReader {
  const GeolocatorReader();

  @override
  Future<LocationAccess> access() async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.off;
    return _access(await Geolocator.checkPermission());
  }

  @override
  Future<LocationAccess> request() async => _access(await Geolocator.requestPermission());

  static LocationAccess _access(LocationPermission permission) => switch (permission) {
        LocationPermission.always || LocationPermission.whileInUse => LocationAccess.granted,
        LocationPermission.denied => LocationAccess.notAsked,
        LocationPermission.deniedForever => LocationAccess.denied,
        LocationPermission.unableToDetermine => LocationAccess.notAsked,
      };

  @override
  Future<ReadPlace?> current() async {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
    return _place(position);
  }

  @override
  Future<ReadPlace?> lastKnown() async {
    final position = await Geolocator.getLastKnownPosition();
    return position == null ? null : _place(position);
  }

  static ReadPlace _place(Position position) => ReadPlace(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyM: position.accuracy,
      );

  @override
  Future<String?> address(double latitude, double longitude) async {
    final found = await placemarkFromCoordinates(latitude, longitude);
    if (found.isEmpty) return null;
    final mark = found.first;
    final street = [mark.thoroughfare, mark.subThoroughfare]
        .whereType<String>()
        .where((part) => part.trim().isNotEmpty)
        .join(' ');
    final parts = [
      if (street.isNotEmpty) street else if (mark.name?.trim().isNotEmpty ?? false) mark.name!,
      if (mark.locality?.trim().isNotEmpty ?? false) mark.locality!,
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  @override
  double distance(double fromLat, double fromLng, double toLat, double toLng) =>
      Geolocator.distanceBetween(fromLat, fromLng, toLat, toLng);
}
