import 'package:flutter/widgets.dart' show StringCharacters;
import '../models/memory.dart';
import '../models/person.dart';
import '../models/place.dart';
import 'api/memory_api.dart';
import 'api/memory_items_api.dart';
import 'api/places_api.dart';
import 'api/saved_api.dart';
import '../utils/formatting.dart';

/// The numbers on the Library's tiles; a `null` is one that could not be read.
final class LibraryCounts {
  const LibraryCounts({
    this.people,
    this.faces = const [],
    this.saved,
    this.openTasks,
    this.visitsThisWeek,
    this.documents,
  });

  final int? people;

  /// Up to three initials of the people saved.
  final List<String> faces;
  final int? saved;
  final int? openTasks;
  final int? visitsThisWeek;
  final int? documents;
}

/// Each count from its own call: one that throws leaves its field `null`, never the others.
Future<LibraryCounts> loadLibraryCounts({
  required MemoryApi memory,
  required SavedApi saved,
  required DocumentsApi documents,
  required PlacesApi places,
  required bool placesOn,
  DateTime? now,
}) async {
  Future<T?> read<T>(Future<T> Function() call) async {
    try {
      return await call();
    } catch (_) {
      return null;
    }
  }

  final since = (now ?? DateTime.now()).subtract(const Duration(days: 7));
  final (people, savedOverview, tasks, visits, docs) = await (
    read(memory.listPeople),
    read(saved.getSaved),
    read(() => memory.listTasks(done: false)),
    // shortcut: the API has no date range, so only the first page counts, enough for a week
    placesOn ? read(places.listVisits) : Future<VisitPage?>.value(),
    read(documents.listDocuments),
  ).wait;
  return LibraryCounts(
    people: people?.length,
    faces: [
      for (final person in people?.take(3) ?? const <PersonSummary>[])
        if (person.name.trim().isNotEmpty) person.name.trim().characters.first.toUpperCase(),
    ],
    saved: savedOverview?.total,
    openTasks: tasks?.length,
    visitsThisWeek: visits?.visits.where((v) => !v.arrivedAt.isBefore(since)).length,
    documents: docs?.length,
  );
}

/// One day of the week: how many conversations, and with whom.
final class LibraryDay {
  const LibraryDay({required this.day, required this.conversations, required this.people});

  final DateTime day;
  final int conversations;
  final List<String> people;
}

/// The last 7 local days, newest first; a day with no conversation is left out.
List<LibraryDay> thisWeek(List<ConversationCard> cards, DateTime now) {
  final today = dayOf(now);
  final first = DateTime(today.year, today.month, today.day - 6);
  final days = <DateTime, List<ConversationCard>>{};
  for (final card in cards) {
    final day = dayOf(card.startedAt);
    if (day.isBefore(first) || day.isAfter(today)) continue;
    days.putIfAbsent(day, () => []).add(card);
  }
  final ordered = days.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final day in ordered)
      LibraryDay(
        day: day,
        conversations: days[day]!.length,
        people: [
          for (final name in {for (final c in days[day]!) ...c.people}) name,
        ],
      ),
  ];
}
