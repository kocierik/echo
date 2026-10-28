import 'package:echo_app/models/today_layout.dart';
import 'package:echo_app/screens/edit_today_screen.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<TodayLayout> changes;

  Future<void> pump(WidgetTester tester, [TodayLayout layout = TodayLayout.defaults]) async {
    changes = [];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: EditTodayScreen(layout: layout, onChanged: changes.add),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('lists every section with its switch', (tester) async {
    await pump(tester, TodayLayout.defaults.toggled(TodaySection.earlier));

    expect(find.text('Edit Today'), findsOneWidget);
    expect(find.text('Drag to reorder. Things to confirm always stay on top.'), findsOneWidget);
    for (final section in TodaySection.values) {
      expect(find.text(section.label), findsOneWidget, reason: section.name);
    }
    final earlier = tester.widget<Switch>(find.byKey(const Key('edit-today-switch-earlier')));
    expect(earlier.value, isFalse);
    final saved = tester.widget<Switch>(find.byKey(const Key('edit-today-switch-saved')));
    expect(saved.value, isTrue);
  });

  testWidgets('a switch hides a section', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('edit-today-switch-people')));
    await tester.pumpAndSettle();

    expect(changes.last.isHidden(TodaySection.people), isTrue);
    expect(tester.widget<Switch>(find.byKey(const Key('edit-today-switch-people'))).value, isFalse);
  });

  testWidgets('dragging reorders', (tester) async {
    await pump(tester);

    final handle = find.byKey(const Key('edit-today-handle-saved'));
    final top = tester.getCenter(find.byKey(const Key('edit-today-handle-routines')));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(kLongPressTimeout);
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(Offset(0, (top.dy - 150 - tester.getCenter(handle).dy) / 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(changes.last.order.first, TodaySection.saved);
  });

  testWidgets('reset restores the defaults', (tester) async {
    await pump(tester, TodayLayout.defaults.moved(5, 0).toggled(TodaySection.people));

    await tester.tap(find.byKey(const Key('edit-today-reset')));
    await tester.pumpAndSettle();

    expect(changes.last.order, TodayLayout.defaults.order);
    expect(changes.last.hidden, isEmpty);
  });
}
