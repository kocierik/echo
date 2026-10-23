import 'package:flutter/foundation.dart';

import '../utils/formatting.dart';

/// Where a thing was saved, read from the phone when the user asked for it.
@immutable
final class SavedPlace {
  const SavedPlace({
    required this.latitude,
    required this.longitude,
    this.accuracyM,
    this.address,
  });

  static SavedPlace? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final latitude = json['latitude'];
    final longitude = json['longitude'];
    if (latitude is! num || longitude is! num) return null;
    final accuracy = json['accuracy_m'];
    final address = json['address'];
    return SavedPlace(
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      accuracyM: accuracy is num ? accuracy.toDouble() : null,
      address: address is String && address.trim().isNotEmpty ? address.trim() : null,
    );
  }

  final double latitude;
  final double longitude;
  final double? accuracyM;

  /// From the phone's geocoder; null when it had none.
  final String? address;

  Map<String, Object?> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'accuracy_m': accuracyM,
        'address': address,
      };
}

/// Someone named when the thing was saved; [id] when Echo knows them (People).
@immutable
final class SavedPerson {
  const SavedPerson({required this.name, this.id});

  final String name;
  final String? id;

  static List<SavedPerson> listFrom(Object? json) => [
        if (json is List)
          for (final entry in json)
            if (entry is Map && entry['name'] is String)
              SavedPerson(name: entry['name'] as String, id: entry['id'] as String?),
      ];
}

/// Something the user asked Echo to keep and find again (`/api/saved`): the car, the
/// passport, a wine, a receipt. One kind of thing for every case.
@immutable
final class SavedItem {
  const SavedItem({
    required this.id,
    required this.listId,
    required this.list,
    required this.title,
    required this.savedAt,
    this.latestOnly = false,
    this.keepDays,
    this.details,
    this.fields = const {},
    this.photoId,
    this.place,
    this.people = const [],
    this.source = 'chat',
  });

  factory SavedItem.fromJson(Map<String, dynamic> json) {
    final fields = json['fields'];
    return SavedItem(
      id: json['id'] as String,
      listId: json['list_id'] as String? ?? '',
      list: json['list'] as String? ?? '',
      latestOnly: json['latest_only'] as bool? ?? false,
      keepDays: (json['keep_days'] as num?)?.toInt(),
      title: json['title'] as String? ?? '',
      details: _text(json['details']),
      fields: fields is Map<String, dynamic> ? fields : const {},
      photoId: json['photo_id'] as String?,
      place: SavedPlace.tryParse(json['place']),
      people: SavedPerson.listFrom(json['people']),
      source: json['source'] as String? ?? 'chat',
      savedAt: _time(json['saved_at']) ?? DateTime.now(),
    );
  }

  final String id;
  final String listId;
  final String list;

  /// Its list keeps only its latest thing (the car), and for [keepDays] at most.
  final bool latestOnly;
  final int? keepDays;
  final String title;
  final String? details;
  final Map<String, dynamic> fields;
  final String? photoId;
  final SavedPlace? place;
  final List<SavedPerson> people;
  final String source;
  final DateTime savedAt;

  /// Its fields in a line: "Level -2 · Column B4", "€12.50 · Shop Esselunga".
  String? get fieldsLine {
    final parts = <String>[];
    final currency = fields['currency'] is String ? fields['currency'] as String : 'EUR';
    for (final MapEntry(:key, :value) in fields.entries) {
      if (key == 'currency' || value == null || '$value'.isEmpty) continue;
      if (key == 'amount' && value is num) {
        parts.add(formatMoney(currency, value.toDouble()));
      } else {
        final label = key.replaceAll('_', ' ');
        parts.add('${label[0].toUpperCase()}${label.substring(1)} $value');
      }
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// "With Marco" from the people, else the details: the line under a title.
  String? get subtitle {
    if (people.isNotEmpty) return 'With ${people.map((p) => p.name.split(' ').first).join(', ')}';
    return details ?? fieldsLine;
  }
}

/// This week's total of a list's amounts.
@immutable
final class SavedSum {
  const SavedSum({required this.count, required this.totals});

  static SavedSum? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final totals = json['totals'];
    return SavedSum(
      count: (json['count'] as num? ?? 0).toInt(),
      totals: {
        if (totals is Map)
          for (final MapEntry(:key, :value) in totals.entries)
            if (key is String && value is num) key: value.toDouble(),
      },
    );
  }

  final int count;
  final Map<String, double> totals;

  /// "€184.30 this week · 7 things".
  String label() {
    final money = totals.entries.map((e) => formatMoney(e.key, e.value)).join(' + ');
    return '$money this week · ${count == 1 ? '1 thing' : '$count things'}';
  }
}

/// A list of the Saved page: its first things, how many in all, the week's total.
@immutable
final class SavedListSummary {
  const SavedListSummary({
    required this.id,
    required this.name,
    required this.count,
    required this.items,
    this.latestOnly = false,
    this.keepDays,
    this.weekSum,
  });

  factory SavedListSummary.fromJson(Map<String, dynamic> json) => SavedListSummary(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        count: (json['count'] as num? ?? 0).toInt(),
        latestOnly: json['latest_only'] as bool? ?? false,
        keepDays: (json['keep_days'] as num?)?.toInt(),
        items: _items(json['items']),
        weekSum: SavedSum.tryParse(json['week_sum']),
      );

  final String id;
  final String name;
  final int count;
  final bool latestOnly;
  final int? keepDays;
  final List<SavedItem> items;
  final SavedSum? weekSum;
}

/// The Saved page (`GET /api/saved`).
@immutable
final class SavedOverview {
  const SavedOverview({
    required this.total,
    required this.places,
    required this.lists,
    this.latestList,
  });

  factory SavedOverview.fromJson(Map<String, dynamic> json) => SavedOverview(
        total: (json['total'] as num? ?? 0).toInt(),
        latestList: json['latest_list'] as String?,
        places: _items(json['places']),
        lists: [
          for (final entry in json['lists'] as List<dynamic>? ?? const [])
            SavedListSummary.fromJson(entry as Map<String, dynamic>),
        ],
      );

  final int total;

  /// The list a thing was last saved in, for Today's row.
  final String? latestList;

  /// The "only the latest" things with a place (the car), shown first as cards.
  final List<SavedItem> places;
  final List<SavedListSummary> lists;
}

/// A list to move a thing to.
@immutable
final class SavedListChoice {
  const SavedListChoice({
    required this.id,
    required this.name,
    required this.count,
    this.latestOnly = false,
    this.keepDays,
  });

  factory SavedListChoice.fromJson(Map<String, dynamic> json) => SavedListChoice(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        count: (json['count'] as num? ?? 0).toInt(),
        latestOnly: json['latest_only'] as bool? ?? false,
        keepDays: (json['keep_days'] as num?)?.toInt(),
      );

  final String id;
  final String name;
  final int count;
  final bool latestOnly;
  final int? keepDays;
}

/// A list and every thing in it ("All N").
@immutable
final class SavedListDetail {
  const SavedListDetail({required this.list, required this.items});

  factory SavedListDetail.fromJson(Map<String, dynamic> json) => SavedListDetail(
        list: SavedListChoice.fromJson(json['list'] as Map<String, dynamic>),
        items: _items(json['items']),
      );

  final SavedListChoice list;
  final List<SavedItem> items;
}

/// The conversation a thing was saved in.
@immutable
final class SavedConversation {
  const SavedConversation({
    required this.id,
    required this.startedAt,
    required this.duration,
    this.title,
  });

  final String id;
  final String? title;
  final DateTime startedAt;
  final Duration duration;
}

/// A thing and its moment (`GET /api/saved/items/{id}`).
@immutable
final class SavedItemDetail {
  const SavedItemDetail({
    required this.item,
    required this.at,
    this.photoText,
    this.people = const [],
    this.request,
    this.conversation,
  });

  factory SavedItemDetail.fromJson(Map<String, dynamic> json) {
    final moment = json['moment'] is Map<String, dynamic>
        ? json['moment'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final conversation = moment['conversation'];
    final item = SavedItem.fromJson(json);
    return SavedItemDetail(
      item: item,
      photoText: _text(json['photo_text']),
      at: _time(moment['at']) ?? item.savedAt,
      people: SavedPerson.listFrom(moment['people']),
      request: _text(moment['request']),
      conversation: conversation is Map<String, dynamic>
          ? SavedConversation(
              id: conversation['id'] as String,
              title: _text(conversation['title']),
              startedAt: _time(conversation['started_at']) ?? item.savedAt,
              duration: Duration(seconds: (conversation['duration_s'] as num? ?? 0).toInt()),
            )
          : null,
    );
  }

  final SavedItem item;

  /// What Echo read on the photo.
  final String? photoText;
  final DateTime at;
  final List<SavedPerson> people;

  /// The request as said ("its line").
  final String? request;
  final SavedConversation? conversation;
}

/// What an answer in Ask saved: a chip opening the thing.
@immutable
final class SavedChip {
  const SavedChip({required this.id, required this.title, required this.list, this.address});

  static List<SavedChip> listFrom(Object? json) => [
        if (json is List)
          for (final entry in json)
            if (entry is Map && entry['id'] is String && entry['title'] is String)
              SavedChip(
                id: entry['id'] as String,
                title: entry['title'] as String,
                list: entry['list'] as String? ?? '',
                address: entry['address'] as String?,
              ),
      ];

  final String id;
  final String title;
  final String list;
  final String? address;

  String get subtitle =>
      address != null ? "$address · from the phone's location" : 'In $list';
}

/// "€184.30", "$20.00", "CHF 5.00".
String formatMoney(String currency, double amount) {
  final value = amount.toStringAsFixed(2);
  return switch (currency.toUpperCase()) {
    'EUR' => '€$value',
    'USD' => '\$$value',
    'GBP' => '£$value',
    final other => '$other $value',
  };
}

/// How long a list keeps its things, in words ("Kept until the next one, or for a
/// week."); null when it keeps them.
String? keepNote({required bool latestOnly, required int? keepDays}) {
  final days = switch (keepDays) {
    null => null,
    1 => 'a day',
    7 => 'a week',
    14 => 'two weeks',
    final n => '$n days',
  };
  if (latestOnly) {
    return days == null ? 'Kept until the next one.' : 'Kept until the next one, or for $days.';
  }
  return days == null ? null : 'Kept for $days.';
}

/// "since 09:40 today", "since yesterday, 09:40", "since Tue, Oct 13".
String sinceLabel(DateTime savedAt, DateTime now) {
  final day = dayLabel(savedAt, now);
  return switch (day) {
    'Today' => 'since ${formatTime(savedAt)} today',
    'Yesterday' => 'since yesterday, ${formatTime(savedAt)}',
    _ => 'since $day',
  };
}

List<SavedItem> _items(Object? json) => [
      if (json is List)
        for (final entry in json) SavedItem.fromJson(entry as Map<String, dynamic>),
    ];

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;
