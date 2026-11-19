import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/memory_items.dart';
import 'package:echo_app/models/person.dart';
import 'package:echo_app/models/place.dart';
import 'package:echo_app/models/saved.dart';
import 'package:echo_app/models/task_item.dart';
import 'package:echo_app/services/api/memory_items_api.dart';
import 'package:echo_app/services/api/places_api.dart';
import 'package:echo_app/services/api/saved_api.dart';
import 'package:echo_app/services/library_counts.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

class _Saved implements SavedApi {
  _Saved(this.total);
  final int? total;
  @override
  Future<SavedOverview> getSaved() async {
    if (total == null) throw StateError('down');
    return SavedOverview(total: total!, places: const [], lists: const []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Docs implements DocumentsApi {
  _Docs(this.count);
  final int count;
  @override
  Future<List<UserDocument>> listDocuments() async => [
        for (var i = 0; i < count; i++)
          UserDocument(id: '$i', title: 'd$i', kind: 'pdf', sizeBytes: 1, status: 'ready', wordCount: 1),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Places implements PlacesApi {
  _Places(this.count, this.now);
  final int count;
  final DateTime now;
  int calls = 0;
  @override
  Future<VisitPage> listVisits({DateTime? before}) async {
    calls++;
    return VisitPage(
      visits: [
        for (var i = 0; i < count; i++) PlaceVisit(id: '$i', arrivedAt: now.subtract(Duration(days: i % 3))),
        // older than a week: not counted
        PlaceVisit(id: 'old', arrivedAt: now.subtract(const Duration(days: 20))),
      ],
      more: false,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ConversationCard card(DateTime at, List<String> people) =>
    ConversationCard(id: '$at', startedAt: at, people: people);

void main() {
  final now = DateTime(2026, 11, 17, 18);

  FakeMemoryApi memory({int people = 0, int tasks = 0}) => FakeMemoryApi(
        openTasks: [for (var i = 0; i < tasks; i++) TaskItem(id: '$i', name: 't$i')],
      )..people = [for (var i = 0; i < people; i++) PersonSummary(id: '$i', name: 'Person $i')];

  test('one failing source does not hide the others', () async {
    final counts = await loadLibraryCounts(
      memory: memory(people: 14, tasks: 3),
      saved: _Saved(null),
      documents: _Docs(3),
      places: _Places(8, now),
      placesOn: true,
      now: now,
    );
    expect(counts.people, 14);
    expect(counts.faces, ['P', 'P', 'P']);
    expect(counts.saved, isNull);
    expect(counts.openTasks, 3);
    expect(counts.visitsThisWeek, 8);
    expect(counts.documents, 3);
  });

  test('places off: no call, no count', () async {
    final places = _Places(8, now);
    final counts = await loadLibraryCounts(
      memory: memory(),
      saved: _Saved(0),
      documents: _Docs(0),
      places: places,
      placesOn: false,
      now: now,
    );
    expect(counts.visitsThisWeek, isNull);
    expect(places.calls, 0);
  });

  test('this week: one row per day with conversations, newest first', () {
    final days = thisWeek([
      card(DateTime(2026, 11, 17, 9), ['Marco']),
      card(DateTime(2026, 11, 17, 12), ['Giulia']),
      card(DateTime(2026, 11, 16, 13), ['Marco']),
      card(DateTime(2026, 11, 9, 10), []),
    ], now);
    expect(days.map((d) => d.day), [DateTime(2026, 11, 17), DateTime(2026, 11, 16)]);
    expect(days.first.conversations, 2);
    expect(days.first.people, ['Marco', 'Giulia']);
  });
}
