import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A section of Today the user can move or hide (Edit Today). What needs the user, the
/// device's warnings and the plan line are not sections: they keep their place.
enum TodaySection {
  routines('From your routines'),
  todo('To do today'),
  comingUp('Coming up today'),
  yourDay('Your day');

  const TodaySection(this.label);

  final String label;
}

/// Today's sections in the user's order, and the ones they hid. Kept on this phone.
@immutable
final class TodayLayout {
  const TodayLayout({required this.order, this.hidden = const {}});

  /// The user's order (28/10), every section shown.
  static const defaults = TodayLayout(order: TodaySection.values);

  final List<TodaySection> order;
  final Set<TodaySection> hidden;

  List<TodaySection> get visible => [
        for (final section in order)
          if (!hidden.contains(section)) section,
      ];

  bool isHidden(TodaySection section) => hidden.contains(section);

  /// [from] dropped at [to], as `ReorderableListView` reports it (indices before removal).
  TodayLayout moved(int from, int to) {
    final next = [...order];
    final section = next.removeAt(from);
    next.insert(to > from ? to - 1 : to, section);
    return TodayLayout(order: List.unmodifiable(next), hidden: hidden);
  }

  TodayLayout toggled(TodaySection section) => TodayLayout(
        order: order,
        hidden: hidden.contains(section)
            ? ({...hidden}..remove(section))
            : {...hidden, section},
      );

  String toJson() => jsonEncode({
        'order': [for (final section in order) section.name],
        'hidden': [for (final section in hidden) section.name],
      });

  /// A saved layout; unknown names are dropped and a section it does not have yet goes
  /// right after the nearest one before it in the default order, shown. Anything
  /// unreadable gives the defaults.
  static TodayLayout fromJson(String? json) {
    if (json == null || json.isEmpty) return defaults;
    final Object? data;
    try {
      data = jsonDecode(json);
    } on FormatException {
      return defaults;
    }
    if (data is! Map || data['order'] is! List) return defaults;
    TodaySection? named(Object? name) =>
        TodaySection.values.where((s) => s.name == name).firstOrNull;
    final order = <TodaySection>[];
    for (final name in data['order'] as List) {
      final section = named(name);
      if (section != null && !order.contains(section)) order.add(section);
    }
    for (final (index, section) in TodaySection.values.indexed) {
      if (order.contains(section)) continue;
      final before = TodaySection.values.take(index).toList().reversed.where(order.contains);
      order.insert(before.isEmpty ? 0 : order.indexOf(before.first) + 1, section);
    }
    final hidden = {
      for (final name in data['hidden'] is List ? data['hidden'] as List : const [])
        if (named(name) case final section?) section,
    };
    return TodayLayout(order: List.unmodifiable(order), hidden: hidden);
  }
}
