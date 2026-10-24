import 'package:echo_app/models/place.dart';
import 'package:echo_app/screens/settings/places_visited_screen.dart';
import 'package:echo_app/services/app/network_policy.dart';
import 'package:echo_app/services/phone/places_visited.dart';
import 'package:echo_app/services/phone/visit_sources.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/phone/places_visited_test.dart' show FakeNetwork, FakePlacesApi, FakeSource;

final now = DateTime(2026, 10, 24, 18);

PlaceVisit visit(String id, DateTime arrived, {String? name, List<VisitConversation> talks = const []}) =>
    PlaceVisit(
      id: id,
      arrivedAt: arrived,
      leftAt: arrived.add(const Duration(hours: 1)),
      name: name,
      address: 'Via Roma 12, Milano',
      conversations: talks,
    );

final class ListingApi extends FakePlacesApi {
  ListingApi(this.visits);

  final List<PlaceVisit> visits;
  final deleted = <String>[];

  @override
  Future<VisitPage> listVisits({DateTime? before}) async =>
      VisitPage(visits: List.of(visits), more: false);

  @override
  Future<void> deleteVisit(String id) async => deleted.add('visit $id');

  @override
  Future<void> deleteVisitDay(DateTime day) async => deleted.add('day ${day.day}');

  @override
  Future<void> deleteAllVisits() async => deleted.add('all');
}

void main() {
  late FakeSource source;
  late PlacesVisitedService places;

  Future<void> pump(WidgetTester tester, ListingApi api, {bool on = false}) async {
    SharedPreferences.setMockInitialValues({if (on) PlacesVisitedService.onKey: true});
    source = FakeSource()..current = on ? VisitAccess.always : VisitAccess.notAsked;
    places = PlacesVisitedService(
      source: source,
      api: api,
      preferences: await SharedPreferences.getInstance(),
      networkAccess: FakeNetwork({NetworkType.wifi}),
      networkPolicy: NetworkPolicy(),
    );
    await places.resume();
    // A phone's height: the opt-in's Continue is on screen
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1100);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: PlacesVisitedScreen(places: places, api: api, clock: () => now),
    ));
    await tester.pumpAndSettle();
  }

  bool switchOn(WidgetTester tester) =>
      tester.widget<Switch>(find.byKey(const Key('places-switch'))).value;

  testWidgets('off by default; turning on explains first, then asks for Always',
      (tester) async {
    await pump(tester, ListingApi([]));
    expect(switchOn(tester), isFalse);

    await tester.tap(find.byKey(const Key('places-switch')));
    await tester.pumpAndSettle();
    expect(find.text('Remember the places you visit?'), findsOneWidget);
    expect(find.textContaining('Kept for 90 days'), findsOneWidget);
    expect(source.requested, isFalse);

    await tester.tap(find.byKey(const Key('places-continue')));
    await tester.pumpAndSettle();

    expect(source.requested, isTrue);
    expect(source.started, isTrue);
    expect(switchOn(tester), isTrue);
    expect(find.textContaining('No places yet'), findsOneWidget);
  });

  testWidgets('without Always it stays off and says why', (tester) async {
    await pump(tester, ListingApi([]));
    source.afterRequest = VisitAccess.whileInUse;

    await tester.tap(find.byKey(const Key('places-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('places-continue')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('places-refused')), findsOneWidget);
    expect(places.isOn, isFalse);
    expect(source.started, isFalse);
  });

  testWidgets('the visits by day, with the conversations held there; delete one and a day',
      (tester) async {
    final api = ListingApi([
      visit('v3', DateTime(2026, 10, 24, 12), name: 'Osteria del Treno',
          talks: const [(id: 'c1', title: 'Lunch with Ada')]),
      visit('v2', DateTime(2026, 10, 23, 20)),
      visit('v1', DateTime(2026, 10, 23, 9), name: 'Virgin Active'),
    ]);
    await pump(tester, api, on: true);

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);
    expect(find.text('Osteria del Treno'), findsOneWidget);
    expect(find.textContaining('Lunch with Ada'), findsOneWidget);
    expect(find.text('Via Roma 12, Milano'), findsOneWidget); // a visit with no name

    await tester.tap(find.byKey(const Key('visit-delete-v3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('places-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Osteria del Treno'), findsNothing);

    await tester.tap(find.text('Delete day'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('places-confirm')));
    await tester.pumpAndSettle();

    expect(api.deleted, ['visit v3', 'day 23']);
    expect(find.text('Virgin Active'), findsNothing);
  });

  testWidgets('turning off stops at once and offers to delete what was kept', (tester) async {
    final api = ListingApi([visit('v1', DateTime(2026, 10, 24, 9), name: 'Virgin Active')]);
    await pump(tester, api, on: true);

    await tester.tap(find.byKey(const Key('places-switch')));
    await tester.pumpAndSettle();

    expect(source.started, isFalse);
    expect(places.isOn, isFalse);
    expect(find.text('Delete the places Echo kept?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('places-confirm')));
    await tester.pumpAndSettle();

    expect(api.deleted, ['all']);
    expect(find.text('Virgin Active'), findsNothing);
  });

  testWidgets('Delete all places asks first', (tester) async {
    final api = ListingApi([visit('v1', DateTime(2026, 10, 24, 9))]);
    await pump(tester, api, on: true);

    await tester.scrollUntilVisible(find.byKey(const Key('places-delete-all')), 100);
    await tester.tap(find.byKey(const Key('places-delete-all')));
    await tester.pumpAndSettle();
    expect(find.text('Delete all places?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(api.deleted, isEmpty);
  });
}
