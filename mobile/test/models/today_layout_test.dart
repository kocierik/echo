import 'dart:convert';

import 'package:echo_app/models/today_layout.dart';
import 'package:echo_app/services/app/today_layout_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test("defaults are the user's order, all visible", () {
    expect(TodayLayout.defaults.order, [
      TodaySection.routines,
      TodaySection.todo,
      TodaySection.comingUp,
      TodaySection.yourDay,
    ]);
    expect(TodayLayout.defaults.visible, TodayLayout.defaults.order);
    expect(TodaySection.values.length, 4);
  });

  test('moved and toggled', () {
    // As ReorderableListView reports it: Your day (3) dropped at the top (0)
    final moved = TodayLayout.defaults.moved(3, 0);
    expect(moved.order.take(2), [TodaySection.yourDay, TodaySection.routines]);
    // Routines (0) dropped below To do (index 2 before removal)
    final down = TodayLayout.defaults.moved(0, 2);
    expect(down.order.take(2), [TodaySection.todo, TodaySection.routines]);

    final hidden = TodayLayout.defaults.toggled(TodaySection.yourDay);
    expect(hidden.isHidden(TodaySection.yourDay), isTrue);
    expect(hidden.visible, isNot(contains(TodaySection.yourDay)));
    expect(hidden.toggled(TodaySection.yourDay).isHidden(TodaySection.yourDay), isFalse);
  });

  test('round trip through json', () {
    final layout = TodayLayout.defaults.moved(3, 0).toggled(TodaySection.yourDay);

    final back = TodayLayout.fromJson(layout.toJson());

    expect(back.order, layout.order);
    expect(back.hidden, {TodaySection.yourDay});
  });

  test('missing sections are added at their default place', () {
    final saved = jsonEncode({
      'order': ['routines', 'todo', 'yourDay'],
      'hidden': ['todo'],
    });

    final layout = TodayLayout.fromJson(saved);

    expect(layout.order, TodaySection.values);
    expect(layout.isHidden(TodaySection.todo), isTrue);
    expect(layout.isHidden(TodaySection.comingUp), isFalse);
  });

  test('a layout saved before the Library keeps the sections Today still has', () {
    final layout = TodayLayout.fromJson(
        '{"order":["people","todo","saved","yourDay","earlier","places"],"hidden":["people"]}');
    expect(layout.order.indexOf(TodaySection.todo),
        lessThan(layout.order.indexOf(TodaySection.yourDay)));
    expect(layout.order.toSet(), TodaySection.values.toSet());
    expect(layout.hidden, isEmpty);
  });

  test('a missing first section goes first', () {
    final layout = TodayLayout.fromJson(jsonEncode({
      'order': ['yourDay', 'todo'],
      'hidden': <String>[],
    }));

    expect(layout.order.first, TodaySection.routines);
    expect(layout.order.indexOf(TodaySection.yourDay), lessThan(layout.order.indexOf(TodaySection.todo)));
    expect(layout.order.toSet().length, TodaySection.values.length);
  });

  test('unknown names and broken json fall back', () {
    final odd = TodayLayout.fromJson(jsonEncode({
      'order': ['weather', 'todo', 'todo', 42],
      'hidden': ['ghost'],
    }));
    expect(odd.order.toSet().length, TodaySection.values.length);
    expect(odd.order.length, TodaySection.values.length);
    expect(odd.hidden, isEmpty);

    for (final broken in [null, '', '{', '[]', '{"order": "x"}']) {
      expect(TodayLayout.fromJson(broken).order, TodayLayout.defaults.order, reason: broken);
    }
  });

  test('the store saves and loads', () async {
    SharedPreferences.setMockInitialValues({});
    final store = TodayLayoutStore();
    expect((await store.load()).order, TodayLayout.defaults.order);

    await store.save(TodayLayout.defaults.toggled(TodaySection.yourDay));

    expect((await TodayLayoutStore().load()).isHidden(TodaySection.yourDay), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(TodayLayoutStore.key), isNotNull);
  });
}
