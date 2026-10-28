import 'package:echo_app/models/place.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/utils/directions.dart';
import 'package:echo_app/widgets/places_today.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PlaceVisit _visit(String id, DateTime arrived,
        {DateTime? left, String? name, String? address, double? lat, double? lng}) =>
    PlaceVisit(
      id: id,
      arrivedAt: arrived,
      leftAt: left,
      name: name,
      address: address,
      latitude: lat,
      longitude: lng,
    );

void main() {
  test('a visit reads its coordinates', () {
    final visit = PlaceVisit.fromJson(const {
      'id': 'v1',
      'arrived_at': '2026-10-28T07:10:00Z',
      'latitude': 45.46,
      'longitude': 9.19,
    });
    final none = PlaceVisit.fromJson(const {'id': 'v2', 'arrived_at': '2026-10-28T07:10:00Z'});

    expect((visit.latitude, visit.longitude), (45.46, 9.19));
    expect((none.latitude, none.longitude), (null, null));
  });

  test('a stay opens in the phone maps, by its place or its name', () {
    final there = _visit('v1', DateTime(2026, 10, 28, 9), name: 'Office', lat: 45.46, lng: 9.19);
    final named = _visit('v2', DateTime(2026, 10, 28, 9), address: 'Via Roma 12, Milano');

    expect(
      visitMapsUri(there, iOS: true),
      Uri.https('maps.apple.com', '/', {'ll': '45.46,9.19', 'q': 'Office'}),
    );
    expect(
      visitMapsUri(there, iOS: false),
      Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': '45.46,9.19'}),
    );
    expect(
      visitMapsUri(named, iOS: true),
      Uri.https('maps.apple.com', '/', {'q': 'Via Roma 12, Milano'}),
    );
    expect(
      visitMapsUri(named, iOS: false),
      Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': 'Via Roma 12, Milano'}),
    );
  });

  test("today's stays only, oldest first", () {
    final stays = visitsOn([
      _visit('late', DateTime(2026, 10, 28, 18)),
      _visit('yesterday', DateTime(2026, 10, 27, 20)),
      _visit('early', DateTime(2026, 10, 28, 8)),
    ], DateTime(2026, 10, 28, 21));

    expect(stays.map((v) => v.id), ['early', 'late']);
  });

  late List<String> opened;
  late int seeAll;

  Future<void> pump(WidgetTester tester, List<PlaceVisit> visits) async {
    opened = [];
    seeAll = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: PlacesTodayPanel(
            visits: visits,
            onOpen: (v) => opened.add(v.id),
            onSeeAll: () => seeAll++,
          ),
        ),
      ),
    ));
  }

  testWidgets('each stay with its time and place; a tap opens it, See all the rest',
      (tester) async {
    await pump(tester, [
      _visit('v1', DateTime(2026, 10, 28, 8, 10), left: DateTime(2026, 10, 28, 8, 50),
          name: 'Home'),
      _visit('v2', DateTime(2026, 10, 28, 9), address: 'Via Roma 12, Milano'),
    ]);

    expect(find.text("Where you've been"), findsOneWidget);
    expect(find.text('08:10–08:50'), findsOneWidget);
    expect(find.text('09:00'), findsOneWidget);
    expect(find.text('Via Roma 12, Milano'), findsOneWidget);

    await tester.tap(find.byKey(const Key('place-v2')));
    await tester.tap(find.byKey(const Key('places-see-all')));

    expect(opened, ['v2']);
    expect(seeAll, 1);
  });

  testWidgets('no stays, no panel', (tester) async {
    await pump(tester, const []);

    expect(find.byKey(const Key('places-today')), findsNothing);
  });
}
