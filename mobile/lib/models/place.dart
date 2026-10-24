import 'package:flutter/foundation.dart';

/// Where a conversation mostly happened: the visit's place (Profile → Places visited).
@immutable
final class ConversationPlace {
  const ConversationPlace({required this.visitId, this.name, this.address});

  static ConversationPlace? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['visit_id'];
    final place = ConversationPlace(
      visitId: id is String ? id : '',
      name: _text(json['name']),
      address: _text(json['address']),
    );
    return place.label == null ? null : place;
  }

  final String visitId;

  /// Apple's place name on iPhone ("Trattoria da Mario"), when the phone knew one.
  final String? name;
  final String? address;

  /// What the place is called: its name, else its address.
  String? get label => name ?? address;
}

/// A stay as the phone recorded it, waiting to be sent (`POST /api/places/visits`).
/// The same stay is sent when it starts ([leftAt] null) and when it ends, under [key].
@immutable
final class RecordedVisit {
  const RecordedVisit({
    required this.key,
    required this.arrivedAt,
    required this.latitude,
    required this.longitude,
    this.leftAt,
    this.accuracyM,
    this.name,
    this.address,
  });

  static RecordedVisit? tryParse(Object? json) {
    if (json is! Map) return null;
    final key = json['key'];
    final arrived = DateTime.tryParse(json['arrived_at'] as String? ?? '');
    final latitude = json['latitude'];
    final longitude = json['longitude'];
    if (key is! String || arrived == null || latitude is! num || longitude is! num) {
      return null;
    }
    final accuracy = json['accuracy_m'];
    return RecordedVisit(
      key: key,
      arrivedAt: arrived,
      leftAt: DateTime.tryParse(json['left_at'] as String? ?? ''),
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      accuracyM: accuracy is num ? accuracy.toDouble() : null,
      name: _text(json['name']),
      address: _text(json['address']),
    );
  }

  final String key;
  final DateTime arrivedAt;

  /// Null while the user is still there.
  final DateTime? leftAt;
  final double latitude;
  final double longitude;
  final double? accuracyM;
  final String? name;
  final String? address;

  RecordedVisit copyWith({DateTime? leftAt, String? name, String? address}) => RecordedVisit(
        key: key,
        arrivedAt: arrivedAt,
        leftAt: leftAt ?? this.leftAt,
        latitude: latitude,
        longitude: longitude,
        accuracyM: accuracyM,
        name: name ?? this.name,
        address: address ?? this.address,
      );

  Map<String, Object?> toJson() => {
        'key': key,
        'arrived_at': arrivedAt.toUtc().toIso8601String(),
        'left_at': leftAt?.toUtc().toIso8601String(),
        'latitude': latitude,
        'longitude': longitude,
        'accuracy_m': accuracyM,
        'name': name,
        'address': address,
      };
}

/// A conversation held during a visit.
typedef VisitConversation = ({String id, String? title});

/// A visit kept on the server, as Profile → Places visited lists it.
@immutable
final class PlaceVisit {
  const PlaceVisit({
    required this.id,
    required this.arrivedAt,
    this.leftAt,
    this.name,
    this.address,
    this.conversations = const [],
  });

  factory PlaceVisit.fromJson(Map<String, dynamic> json) => PlaceVisit(
        id: json['id'] as String,
        arrivedAt: DateTime.parse(json['arrived_at'] as String),
        leftAt: DateTime.tryParse(json['left_at'] as String? ?? ''),
        name: _text(json['name']),
        address: _text(json['address']),
        conversations: [
          for (final entry in json['conversations'] as List<dynamic>? ?? const [])
            if (entry is Map && entry['id'] is String)
              (id: entry['id'] as String, title: _text(entry['title'])),
        ],
      );

  final String id;
  final DateTime arrivedAt;

  /// Null while the user is still there.
  final DateTime? leftAt;
  final String? name;
  final String? address;
  final List<VisitConversation> conversations;

  /// Its name, else its address, else a plain word.
  String get label => name ?? address ?? 'A place';
}

/// A page of visits, newest first; [more] when older ones follow.
@immutable
final class VisitPage {
  const VisitPage({required this.visits, required this.more});

  factory VisitPage.fromJson(Map<String, dynamic> json) => VisitPage(
        visits: [
          for (final item in json['visits'] as List<dynamic>? ?? const [])
            PlaceVisit.fromJson(item as Map<String, dynamic>),
        ],
        more: json['more'] as bool? ?? false,
      );

  final List<PlaceVisit> visits;
  final bool more;
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
