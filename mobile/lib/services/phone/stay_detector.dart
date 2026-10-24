import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../models/place.dart';

/// A position the phone read (on Android, every few minutes at low power).
@immutable
final class Fix {
  const Fix({
    required this.latitude,
    required this.longitude,
    required this.at,
    this.accuracyM,
  });

  final double latitude;
  final double longitude;
  final double? accuracyM;
  final DateTime at;
}

/// Android has no visit detection of its own: the stays are worked out here, on the
/// phone, from the positions the foreground service gets. Only the stay going on is kept
/// (its centre and times), never the positions themselves or the way between places.
///
/// A position within [radiusM] of the stay's centre extends it. One far away is held:
/// a second far one in a row means the phone left (the stay ends at the last position
/// inside it), while one inside again means the far one was a bad fix. A stay is a visit
/// from [minStay]: it is sent once open when it gets there, and once more when it ends.
final class StayDetector {
  StayDetector({
    this.radiusM = 150,
    this.minStay = const Duration(minutes: 10),
    this.maxAccuracyM = 300,
  });

  /// The stay going on, as [toJson] wrote it; a broken one is forgotten.
  factory StayDetector.fromJson(Map<String, Object?> json) {
    final detector = StayDetector();
    try {
      final stay = json['stay'];
      if (stay is Map) detector._stay = _Stay.fromJson(stay);
      final away = json['away'];
      if (away is Map) detector._away = _fixFrom(away);
    } catch (_) {
      detector
        .._stay = null
        .._away = null;
    }
    return detector;
  }

  final double radiusM;
  final Duration minStay;
  final double maxAccuracyM;

  _Stay? _stay;
  Fix? _away;

  /// The visits [fix] starts or ends (usually none).
  List<RecordedVisit> add(Fix fix) {
    if ((fix.accuracyM ?? 0) > maxAccuracyM) return const [];
    final stay = _stay;
    if (stay == null) {
      _stay = _Stay.at(fix);
      return const [];
    }
    if (_metres(stay.latitude, stay.longitude, fix.latitude, fix.longitude) <= radiusM) {
      _away = null;
      stay.extend(fix);
      if (!stay.openSent && stay.lastAt.difference(stay.arrivedAt) >= minStay) {
        stay.openSent = true;
        return [stay.visit(open: true)];
      }
      return const [];
    }
    final away = _away;
    if (away == null) {
      _away = fix;
      return const [];
    }
    // Left: the stay ends, and a new one may start where the phone went
    final ended = stay.lastAt.difference(stay.arrivedAt) >= minStay
        ? [stay.visit(open: false)]
        : const <RecordedVisit>[];
    final next = _Stay.at(away);
    if (_metres(away.latitude, away.longitude, fix.latitude, fix.longitude) <= radiusM) {
      next.extend(fix);
      _stay = next;
    } else {
      _stay = _Stay.at(fix);
    }
    _away = null;
    return ended;
  }

  Map<String, Object?> toJson() => {
        'stay': _stay?.toJson(),
        'away': _away == null ? null : _fixJson(_away!),
      };
}

final class _Stay {
  _Stay({
    required this.latitude,
    required this.longitude,
    required this.arrivedAt,
    required this.lastAt,
    this.accuracyM,
    this.count = 1,
    this.openSent = false,
  });

  factory _Stay.at(Fix fix) => _Stay(
        latitude: fix.latitude,
        longitude: fix.longitude,
        accuracyM: fix.accuracyM,
        arrivedAt: fix.at,
        lastAt: fix.at,
      );

  factory _Stay.fromJson(Map json) => _Stay(
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        accuracyM: (json['accuracy_m'] as num?)?.toDouble(),
        arrivedAt: DateTime.parse(json['arrived_at'] as String),
        lastAt: DateTime.parse(json['last_at'] as String),
        count: json['count'] as int? ?? 1,
        openSent: json['open_sent'] as bool? ?? false,
      );

  /// The centre: the mean of the positions inside it (the latest ones weigh more after
  /// a while, so a slow drift is followed).
  double latitude;
  double longitude;
  double? accuracyM;
  final DateTime arrivedAt;
  DateTime lastAt;
  int count;
  bool openSent;

  static const _maxWeight = 20;

  void extend(Fix fix) {
    final weight = math.min(count, _maxWeight);
    latitude = (latitude * weight + fix.latitude) / (weight + 1);
    longitude = (longitude * weight + fix.longitude) / (weight + 1);
    final accuracy = fix.accuracyM;
    if (accuracy != null) accuracyM = math.min(accuracyM ?? accuracy, accuracy);
    lastAt = fix.at;
    count += 1;
  }

  RecordedVisit visit({required bool open}) => RecordedVisit(
        key: 'android:${arrivedAt.millisecondsSinceEpoch}',
        arrivedAt: arrivedAt,
        leftAt: open ? null : lastAt,
        latitude: latitude,
        longitude: longitude,
        accuracyM: accuracyM,
      );

  Map<String, Object?> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'accuracy_m': accuracyM,
        'arrived_at': arrivedAt.toUtc().toIso8601String(),
        'last_at': lastAt.toUtc().toIso8601String(),
        'count': count,
        'open_sent': openSent,
      };
}

Map<String, Object?> _fixJson(Fix fix) => {
      'latitude': fix.latitude,
      'longitude': fix.longitude,
      'accuracy_m': fix.accuracyM,
      'at': fix.at.toUtc().toIso8601String(),
    };

Fix _fixFrom(Map json) => Fix(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      accuracyM: (json['accuracy_m'] as num?)?.toDouble(),
      at: DateTime.parse(json['at'] as String),
    );

/// Metres between two points (haversine).
double _metres(double lat1, double lng1, double lat2, double lng2) {
  const earth = 6371000.0;
  double rad(double degrees) => degrees * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * earth * math.asin(math.sqrt(a));
}
