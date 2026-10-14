import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/person.dart';
import 'package:echo_app/screens/person_screen.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

void main() {
  final now = DateTime(2026, 10, 14, 18);

  PersonDetail marco({bool linked = true}) => PersonDetail(
        person: PersonSummary(
          id: 'p1',
          name: 'Marco Rossi',
          role: 'designer',
          about: 'Leads the Atlas design.',
          lastSeen: DateTime(2026, 10, 13, 9),
          conversationCount: 2,
          openTaskCount: 1,
        ),
        conversations: linked
            ? [card('c1', startedAt: DateTime(2026, 10, 13, 9), title: 'Atlas design review')]
            : const [],
        tasks: linked
            ? [task('t1', 'Send Marco the specs', due: DateTime(2026, 10, 15), source: '[Tu] Mando le specifiche a Marco.')]
            : const [],
        events: linked
            ? const [
                MemoryEntity(
                  id: 'e1',
                  type: 'event',
                  name: 'Dinner with Marco',
                  metadata: {'event_date': '2026-10-17', 'event_time': '20:00'},
                ),
              ]
            : const [],
      );

  Future<List<String>> pump(WidgetTester tester, FakeMemoryApi api) async {
    final asked = <String>[];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PersonScreen(
                personId: 'p1',
                api: api,
                onAsk: asked.add,
                clock: () => now,
              ),
            )),
            child: const Text('tabs'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('tabs'));
    await tester.pumpAndSettle();
    return asked;
  }

  testWidgets('shows who they are and everything linked to them', (tester) async {
    await pump(tester, FakeMemoryApi()..personDetails = {'p1': marco()});

    expect(find.text('MR'), findsOneWidget);
    expect(find.text('Marco Rossi'), findsOneWidget);
    expect(find.text('designer · Seen yesterday'), findsOneWidget);
    expect(find.text('Leads the Atlas design.'), findsOneWidget);
    expect(find.text('Send Marco the specs'), findsOneWidget);
    expect(find.text('Tomorrow'), findsOneWidget);
    expect(find.text('Dinner with Marco'), findsOneWidget);
    expect(find.text('Sat, Oct 17 at 20:00'), findsOneWidget);
    expect(find.text('Atlas design review'), findsOneWidget);
  });

  testWidgets('Ask goes back to the tabs and asks about them', (tester) async {
    final asked = await pump(tester, FakeMemoryApi()..personDetails = {'p1': marco()});

    await tester.tap(find.byKey(const Key('person-ask')));
    await tester.pumpAndSettle();

    expect(asked.single, contains('Marco Rossi'));
    expect(find.text('tabs'), findsOneWidget);
  });

  testWidgets('a task can be completed from the person', (tester) async {
    final api = FakeMemoryApi()..personDetails = {'p1': marco()};
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('task-toggle-t1')));
    await tester.pumpAndSettle();

    expect(api.calls, contains('done t1 true'));
  });

  testWidgets('nothing linked yet, and a retry after a failure', (tester) async {
    final api = FakeMemoryApi()..peopleError = serverError('Offline');
    await pump(tester, api);
    expect(find.text('Could not load this person'), findsOneWidget);

    api
      ..peopleError = null
      ..personDetails = {'p1': marco(linked: false)};
    await tester.tap(find.byKey(const Key('person-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing else is linked to Marco Rossi yet.'), findsOneWidget);
  });
}
