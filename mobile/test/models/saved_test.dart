import 'package:echo_app/models/saved.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> itemJson({
  String id = 'i1',
  String title = 'Barolo 2019',
  String list = 'Wines',
  Map<String, dynamic> fields = const {},
  Map<String, dynamic>? place,
  bool latestOnly = false,
  int? keepDays,
  String? photoId,
}) =>
    {
      'id': id,
      'list_id': 'l1',
      'list': list,
      'latest_only': latestOnly,
      'keep_days': keepDays,
      'title': title,
      'details': 'Cantina Rinaldi',
      'fields': fields,
      'photo_id': photoId,
      'place': place,
      'people': [
        {'name': 'Marco Rossi', 'id': 'p1'},
        {'name': 'Giulia', 'id': null},
      ],
      'source': 'voice',
      'saved_at': '2026-10-18T19:40:00Z',
      'updated_at': '2026-10-18T19:40:00Z',
    };

void main() {
  test('a saved thing is read with its place and people', () {
    final item = SavedItem.fromJson(itemJson(
      place: {'latitude': 45.46, 'longitude': 9.19, 'accuracy_m': 12, 'address': 'Via Roma 12'},
      fields: {'level': '-2', 'column': 'B4'},
    ));

    expect(item.title, 'Barolo 2019');
    expect(item.place!.address, 'Via Roma 12');
    expect(item.place!.latitude, 45.46);
    expect(item.people.map((p) => p.name), ['Marco Rossi', 'Giulia']);
    expect(item.people.last.id, isNull);
    expect(item.fieldsLine, 'Level -2 · Column B4');
  });

  test('an amount reads as money and the currency is not repeated', () {
    final item = SavedItem.fromJson(itemJson(fields: {'amount': 12.5, 'currency': 'EUR', 'shop': 'Esselunga'}));

    expect(item.fieldsLine, '€12.50 · Shop Esselunga');
  });

  test('a week sum says the total and how many', () {
    expect(
      const SavedSum(count: 7, totals: {'EUR': 184.3}).label(),
      '€184.30 this week · 7 things',
    );
    expect(
      const SavedSum(count: 1, totals: {'EUR': 3, 'USD': 20}).label(),
      '€3.00 + \$20.00 this week · 1 thing',
    );
    expect(const SavedSum(count: 2, totals: {'CHF': 5}).label(), 'CHF 5.00 this week · 2 things');
  });

  test('how long a list keeps its things, in words', () {
    expect(keepNote(latestOnly: true, keepDays: 7), 'Kept until the next one, or for a week.');
    expect(keepNote(latestOnly: true, keepDays: null), 'Kept until the next one.');
    expect(keepNote(latestOnly: false, keepDays: 3), 'Kept for 3 days.');
    expect(keepNote(latestOnly: false, keepDays: null), isNull);
  });

  test('since when, today or another day', () {
    final now = DateTime(2026, 10, 18, 18, 0);
    expect(sinceLabel(DateTime(2026, 10, 18, 9, 40), now), 'since 09:40 today');
    expect(sinceLabel(DateTime(2026, 10, 17, 9, 40), now), 'since yesterday, 09:40');
    expect(sinceLabel(DateTime(2026, 10, 13, 9, 40), now), 'since Tue, Oct 13');
  });

  test('the overview, its lists and the moment of a thing', () {
    final overview = SavedOverview.fromJson({
      'total': 3,
      'latest_list': 'Wines',
      'places': [itemJson(id: 'car', title: 'Car', list: 'Your car', latestOnly: true, keepDays: 7)],
      'lists': [
        {
          'id': 'l1',
          'name': 'Wines',
          'latest_only': false,
          'keep_days': null,
          'count': 2,
          'updated_at': '2026-10-18T19:40:00Z',
          'items': [itemJson(), itemJson(id: 'i2', title: 'Etna')],
          'week_sum': {
            'count': 2,
            'totals': {'EUR': 20.0},
          },
        },
      ],
    });
    expect(overview.total, 3);
    expect(overview.places.single.latestOnly, isTrue);
    expect(overview.lists.single.items.length, 2);
    expect(overview.lists.single.weekSum!.count, 2);

    final detail = SavedItemDetail.fromJson({
      ...itemJson(photoId: 'ph1'),
      'photo_text': 'Barolo DOCG 2019.',
      'moment': {
        'at': '2026-10-18T19:40:00Z',
        'people': [
          {'name': 'Marco', 'id': null},
        ],
        'request': 'Echo, salvami questo vino',
        'conversation': {
          'id': 'c1',
          'title': 'Cena con Marco',
          'started_at': '2026-10-18T19:00:00Z',
          'duration_s': 4320,
        },
      },
    });
    expect(detail.item.photoId, 'ph1');
    expect(detail.photoText, 'Barolo DOCG 2019.');
    expect(detail.request, 'Echo, salvami questo vino');
    expect(detail.conversation!.duration, const Duration(minutes: 72));
  });

  test('the chip of an answer that saved something', () {
    final chips = SavedChip.listFrom([
      {'id': 'i1', 'title': 'Car', 'list': 'Your car', 'address': 'Via Roma 12'},
      'junk',
      {'title': 'no id'},
    ]);

    expect(chips.single.title, 'Car');
    expect(chips.single.subtitle, 'Via Roma 12 · from the phone\'s location');
    expect(
      SavedChip.listFrom([
        {'id': 'i2', 'title': 'Dune', 'list': 'Books'},
      ]).single.subtitle,
      'In Books',
    );
  });
}
