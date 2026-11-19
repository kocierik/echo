import 'package:echo_app/models/saved.dart';
import 'package:echo_app/screens/saved_item_screen.dart';
import 'package:echo_app/screens/saved_screen.dart';
import 'package:echo_app/services/api/saved_api.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/utils/directions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 10, 23, 18);

SavedItem _item(
  String id,
  String title, {
  String list = 'Wines',
  SavedPlace? place,
  bool latestOnly = false,
  int? keepDays,
  String? details,
  List<SavedPerson> people = const [],
}) =>
    SavedItem(
      id: id,
      listId: 'list-$list',
      list: list,
      title: title,
      details: details,
      place: place,
      people: people,
      latestOnly: latestOnly,
      keepDays: keepDays,
      savedAt: DateTime(2026, 10, 23, 9, 40),
    );

const _viaRoma = SavedPlace(latitude: 45.46, longitude: 9.19, address: 'Via Roma 12, Milano');

final class _FakeSavedApi implements SavedApi {
  _FakeSavedApi(this.overview);

  SavedOverview overview;
  final deleted = <String>[];
  final moved = <(String, String)>[];
  final searches = <String>[];
  SavedItemDetail? detail;

  @override
  Future<SavedOverview> getSaved() async => overview;

  @override
  Future<List<SavedItem>> searchSaved(String query) async {
    searches.add(query);
    return [_item('b1', 'Dune', list: 'Books', details: 'From Giulia')];
  }

  @override
  Future<void> deleteSavedItem(String id) async {
    deleted.add(id);
    overview = SavedOverview(
      total: overview.total - 1,
      places: overview.places.where((i) => i.id != id).toList(),
      lists: overview.lists,
    );
  }

  @override
  Future<SavedItemDetail> getSavedItem(String id) async => detail!;

  @override
  Future<List<SavedListChoice>> listSavedLists() async => const [
        SavedListChoice(id: 'list-Wines', name: 'Wines', count: 2),
        SavedListChoice(id: 'list-Books', name: 'Books', count: 1),
      ];

  @override
  Future<SavedItem> moveSavedItem(String id, String list) async {
    moved.add((id, list));
    return _item(id, 'x', list: list);
  }

  @override
  Future<SavedListDetail> getSavedList(String id) async => SavedListDetail(
        list: const SavedListChoice(id: 'list-Wines', name: 'Wines', count: 5),
        items: [for (var i = 0; i < 5; i++) _item('w$i', 'Wine $i')],
      );

  @override
  Future<SavedItem> putSavedPlace(String id, SavedPlace place) async => _item(id, 'x');
}

SavedOverview _overview() => SavedOverview(
      total: 5,
      latestList: 'Wines',
      places: [_item('car', 'Car', list: 'Your car', place: _viaRoma, latestOnly: true, keepDays: 7)],
      lists: [
        SavedListSummary(
          id: 'list-Wines',
          name: 'Wines',
          count: 5,
          items: [
            _item('w1', 'Barolo 2019', people: const [SavedPerson(name: 'Marco Rossi')]),
            _item('w2', 'Vermentino'),
          ],
        ),
        const SavedListSummary(
          id: 'list-Receipts',
          name: 'Receipts',
          count: 7,
          items: [],
          weekSum: SavedSum(count: 7, totals: {'EUR': 184.3}),
        ),
      ],
    );

Future<List<Uri>> _show(WidgetTester tester, _FakeSavedApi api) async {
  final opened = <Uri>[];
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light,
    home: SavedScreen(
      api: api,
      clock: () => _now,
      openLink: (uri) async => opened.add(uri),
    ),
  ));
  await tester.pumpAndSettle();
  return opened;
}

void main() {
  testWidgets('at 2.0 text scale Saved does not overflow', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _show(tester, _FakeSavedApi(_overview()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('places first, then the lists and a list with amounts as its total',
      (tester) async {
    await _show(tester, _FakeSavedApi(_overview()));

    expect(find.text('Things to find again, each with its moment.'), findsOneWidget);
    expect(find.text('Your car'), findsOneWidget);
    expect(find.text('since 09:40 today'), findsOneWidget);
    expect(find.text('Via Roma 12, Milano'), findsOneWidget);
    expect(find.text('Kept until the next one, or for a week.'), findsOneWidget);
    expect(find.text('Barolo 2019'), findsOneWidget);
    expect(find.textContaining('With Marco'), findsOneWidget);
    expect(find.text('All 5'), findsOneWidget);
    expect(find.text('€184.30 this week · 7 things'), findsOneWidget);
  });

  testWidgets('Directions open the maps, Found it removes the car', (tester) async {
    final api = _FakeSavedApi(_overview());
    final opened = await _show(tester, api);

    await tester.tap(find.byKey(const Key('saved-directions-car')));
    await tester.tap(find.byKey(const Key('saved-found-car')));
    await tester.pumpAndSettle();

    expect(opened.single.toString(), contains('45.46%2C9.19'));
    expect(api.deleted, ['car']);
    expect(find.text('Your car'), findsNothing);
  });

  testWidgets('the search shows what matches', (tester) async {
    final api = _FakeSavedApi(_overview());
    await _show(tester, api);

    await tester.enterText(find.byKey(const Key('saved-search')), 'giulia');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(api.searches, ['giulia']);
    expect(find.text('Dune'), findsOneWidget);
    expect(find.text('Your car'), findsNothing);
  });

  testWidgets('nothing saved yet says how to save', (tester) async {
    await _show(tester, _FakeSavedApi(const SavedOverview(total: 0, places: [], lists: [])));

    expect(find.text('Nothing saved yet'), findsOneWidget);
    expect(find.textContaining('Echo, save this'), findsOneWidget);
  });

  testWidgets('All N opens the whole list', (tester) async {
    await _show(tester, _FakeSavedApi(_overview()));

    await tester.tap(find.text('All 5'));
    await tester.pumpAndSettle();

    expect(find.text('Wine 4'), findsOneWidget);
  });

  group('a saved thing', () {
    SavedItemDetail detail() => SavedItemDetail(
          item: _item('w1', 'Barolo 2019', details: 'Cantina Rinaldi', place: _viaRoma),
          at: DateTime(2026, 10, 18, 21, 40),
          photoText: 'Barolo DOCG 2019, Cantina Rinaldi.',
          people: const [SavedPerson(name: 'Marco', id: 'p1')],
          request: 'Echo, salvami questo vino',
          conversation: SavedConversation(
            id: 'c1',
            title: 'Cena con Marco',
            startedAt: DateTime(2026, 10, 18, 21),
            duration: const Duration(minutes: 72),
          ),
        );

    Future<(List<String>, List<String>)> showItem(WidgetTester tester, _FakeSavedApi api) async {
      final asked = <String>[];
      final people = <String>[];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(
                builder: (_) => SavedItemScreen(
                  itemId: 'w1',
                  api: api,
                  onAsk: asked.add,
                  openPerson: (context, id) async => people.add(id),
                  clock: () => _now,
                ),
              )),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return (asked, people);
    }

    testWidgets('shows its moment and what Echo read', (tester) async {
      final api = _FakeSavedApi(_overview())..detail = detail();
      final (_, people) = await showItem(tester, api);

      expect(find.text('WINES'), findsOneWidget);
      expect(find.text('Sunday 18 October, 21:40'), findsOneWidget);
      expect(find.text('Via Roma 12, Milano'), findsOneWidget);
      expect(find.text('Cena con Marco'), findsOneWidget);
      expect(find.text('1 h 12 min'), findsOneWidget);
      expect(find.text('"Echo, salvami questo vino"'), findsOneWidget);
      expect(find.text('Barolo DOCG 2019, Cantina Rinaldi.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('saved-person-Marco')));
      expect(people, ['p1']);
    });

    testWidgets('Ask about it goes to Ask with the thing', (tester) async {
      final api = _FakeSavedApi(_overview())..detail = detail();
      final (asked, _) = await showItem(tester, api);

      await tester.scrollUntilVisible(find.byKey(const Key('saved-ask')), 200);
      await tester.ensureVisible(find.byKey(const Key('saved-ask')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('saved-ask')));
      await tester.pumpAndSettle();

      expect(asked.single, contains('"Barolo 2019"'));
    });

    testWidgets('Move to… another list, or a new one', (tester) async {
      final api = _FakeSavedApi(_overview())..detail = detail();
      await showItem(tester, api);

      await tester.scrollUntilVisible(find.byKey(const Key('saved-move')), 200);
      await tester.ensureVisible(find.byKey(const Key('saved-move')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('saved-move')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('move-to-list-Wines')), findsNothing); // its own
      await tester.tap(find.byKey(const Key('move-to-list-Books')));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.byKey(const Key('saved-move')), 200);
      await tester.ensureVisible(find.byKey(const Key('saved-move')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('saved-move')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('move-new-list')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('new-list-name')), 'Cellar');
      await tester.tap(find.byKey(const Key('new-list-create')));
      await tester.pumpAndSettle();

      expect(api.moved, [('w1', 'Books'), ('w1', 'Cellar')]);
    });

    testWidgets('Remove asks first, then removes only the thing', (tester) async {
      final api = _FakeSavedApi(_overview())..detail = detail();
      await showItem(tester, api);

      await tester.scrollUntilVisible(find.byKey(const Key('saved-remove')), 200);
      await tester.ensureVisible(find.byKey(const Key('saved-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('saved-remove')));
      await tester.pumpAndSettle();
      expect(find.textContaining('stay in your memory'), findsOneWidget);
      await tester.tap(find.byKey(const Key('saved-remove-confirm')));
      await tester.pumpAndSettle();

      expect(api.deleted, ['w1']);
      expect(find.text('open'), findsOneWidget); // back where it was opened
    });
  });

  test('directions in Apple Maps on iOS, Google Maps on Android', () {
    expect(
      directionsUri(_viaRoma, iOS: true).toString(),
      'https://maps.apple.com/?daddr=45.46%2C9.19',
    );
    expect(
      directionsUri(_viaRoma, iOS: false).toString(),
      'https://www.google.com/maps/dir/?api=1&destination=45.46%2C9.19',
    );
  });
}
