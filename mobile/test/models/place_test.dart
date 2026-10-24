import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/place.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a conversation carries its place, called by its name else its address', () {
    final named = ConversationCard.fromJson(const {
      'id': 'c1',
      'started_at': '2026-10-17T19:00:00Z',
      'place': {'visit_id': 'v1', 'name': 'Trattoria da Mario', 'address': 'Via Roma 12'},
    });
    final street = ConversationCard.fromJson(const {
      'id': 'c2',
      'started_at': '2026-10-17T19:00:00Z',
      'place': {'visit_id': 'v2', 'name': null, 'address': 'Via Roma 12'},
    });
    final nowhere = ConversationCard.fromJson(const {
      'id': 'c3',
      'started_at': '2026-10-17T19:00:00Z',
      'place': null,
    });

    expect(named.place?.label, 'Trattoria da Mario');
    expect(named.place?.visitId, 'v1');
    expect(street.place?.label, 'Via Roma 12');
    expect(nowhere.place, isNull);
  });

  test('a recorded stay goes to the server in UTC and comes back from storage', () {
    final visit = RecordedVisit(
      key: 'android:1',
      arrivedAt: DateTime.utc(2026, 10, 17, 19, 55),
      latitude: 45.46,
      longitude: 9.19,
      accuracyM: 40,
      address: 'Via Garibaldi 5, Milano',
    );

    final json = visit.toJson();
    final back = RecordedVisit.tryParse(json)!;

    expect(json['arrived_at'], '2026-10-17T19:55:00.000Z');
    expect(json['left_at'], isNull);
    expect(back.key, 'android:1');
    expect(back.address, 'Via Garibaldi 5, Milano');
    expect(back.copyWith(leftAt: DateTime.utc(2026, 10, 17, 23)).leftAt,
        DateTime.utc(2026, 10, 17, 23));
    expect(RecordedVisit.tryParse({'key': 'x'}), isNull);
  });

  test('a page of visits with the conversations held there', () {
    final page = VisitPage.fromJson(const {
      'visits': [
        {
          'id': 'v1',
          'arrived_at': '2026-10-17T19:55:00Z',
          'left_at': null,
          'name': null,
          'address': null,
          'conversations': [
            {'id': 'c1', 'title': 'Cena con Marco'},
          ],
        },
      ],
      'more': true,
    });

    expect(page.more, isTrue);
    final visit = page.visits.single;
    expect(visit.leftAt, isNull);
    expect(visit.label, 'A place');
    expect(visit.conversations.single.title, 'Cena con Marco');
  });
}
