import 'dart:async';

import 'package:echo_app/screens/settings/example_data_screen.dart';
import 'package:echo_app/services/api/demo_api.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Api implements ExampleDataApi {
  _Api({this.on = false});

  bool on;
  final sets = <bool>[];
  bool fail = false;
  Completer<void>? gate;

  @override
  Future<bool> exampleDataOn() async => on;

  @override
  Future<bool> setExampleData(bool value) async {
    sets.add(value);
    await gate?.future;
    if (fail) throw Exception('down');
    on = value;
    return on;
  }
}

Future<void> _pump(WidgetTester tester, _Api api) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light,
    home: ExampleDataScreen(api: api),
  ));
  await tester.pumpAndSettle();
}

Switch _switch(WidgetTester tester) =>
    tester.widget<Switch>(find.byKey(const Key('example-data-switch')));

void main() {
  testWidgets('turned on, it says Echo is reading the conversations', (tester) async {
    final api = _Api();
    await _pump(tester, api);
    expect(_switch(tester).value, isFalse);

    await tester.tap(find.byKey(const Key('example-data-switch')));
    await tester.pumpAndSettle();

    expect(api.sets, [true]);
    expect(_switch(tester).value, isTrue);
    expect(find.byKey(const Key('example-data-reading')), findsOneWidget);
  });

  testWidgets('turned off, they are removed', (tester) async {
    final api = _Api(on: true);
    await _pump(tester, api);
    expect(find.byKey(const Key('example-data-reading')), findsNothing);

    await tester.tap(find.byKey(const Key('example-data-switch')));
    await tester.pumpAndSettle();

    expect(api.sets, [false]);
    expect(_switch(tester).value, isFalse);
  });

  testWidgets('one change at a time, and a failure is said', (tester) async {
    final api = _Api()..gate = Completer<void>();
    await _pump(tester, api);

    await tester.tap(find.byKey(const Key('example-data-switch')));
    await tester.pump();
    expect(_switch(tester).onChanged, isNull);

    api.fail = true;
    api.gate!.complete();
    await tester.pumpAndSettle();

    expect(_switch(tester).value, isFalse);
    expect(find.text('Echo could not add the examples. Try again.'), findsOneWidget);
  });
}
