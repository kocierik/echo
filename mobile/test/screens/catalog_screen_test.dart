import 'package:echo_app/models/assistant.dart';
import 'package:echo_app/models/routine.dart';
import 'package:echo_app/models/routine_catalog.dart';
import 'package:echo_app/screens/catalog_screen.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Catalog implements RoutineCatalogApi, AssistantsApi {
  final added = <String, String>{}; // key -> routine id
  final addedAt = <String?>[];
  final deleted = <String>[];
  final created = <AssistantDraft>[];
  List<Assistant> assistants = [];

  CatalogRoutine _entry(String key, String title, String kind) => CatalogRoutine(
        key: key,
        emoji: '☀️',
        title: title,
        summary: 'A summary',
        instruction: 'Do the thing.',
        example: 'An example.',
        schedule: {'kind': kind, 'time': '08:00'},
        scheduleText: 'every day at 08:00',
        routineId: added[key],
      );

  @override
  Future<List<CatalogRoutine>> routineCatalog() async => [
        _entry('morning_brief', 'Morning briefing', 'daily'),
        _entry('weekly_summary', 'Week in review', 'weekly'),
        _entry('meeting_decisions', 'Decisions after each meeting', 'after_conversation'),
      ];

  @override
  Future<Routine> addCatalogRoutine(String key, {String? time}) async {
    added[key] = 'r-$key';
    addedAt.add(time);
    return Routine.fromJson({'id': 'r-$key', 'instruction': 'Do the thing.'});
  }

  @override
  Future<void> deleteRoutine(String id) async {
    deleted.add(id);
    added.removeWhere((_, value) => value == id);
  }

  @override
  Future<List<AssistantTemplate>> assistantTemplates() async => const [
        AssistantTemplate(key: 'work', name: 'Work', emoji: '💼', instructions: 'Work help. More.'),
        AssistantTemplate(key: 'diet', name: 'Diet', emoji: '🥗', instructions: 'Food help.'),
      ];

  @override
  Future<List<Assistant>> listAssistants() async => assistants;

  @override
  Future<Assistant> createAssistant(AssistantDraft draft) async {
    created.add(draft);
    final made = Assistant.fromJson({'id': 'a${created.length}', 'name': draft.name});
    assistants = [...assistants, made];
    return made;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_Catalog> _pump(WidgetTester tester, {CatalogTab tab = CatalogTab.routines}) async {
  final api = _Catalog();
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark,
    home: CatalogScreen(routines: api, assistants: api, initialTab: tab),
  ));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('routines come grouped by how often, and Add adds one at its own time',
      (tester) async {
    final api = await _pump(tester);

    expect(find.text('EVERY DAY'), findsOneWidget);
    expect(find.text('EVERY WEEK'), findsOneWidget);
    expect(find.text('AFTER EACH CONVERSATION'), findsOneWidget);

    await tester.tap(find.byKey(const Key('catalog-add-morning_brief')));
    await tester.pumpAndSettle();

    expect(api.added.keys, ['morning_brief']);
    expect(api.addedAt, [null]);
    expect(
      find.descendant(
          of: find.byKey(const Key('catalog-add-morning_brief')), matching: find.text('Added')),
      findsOneWidget,
    );
  });

  testWidgets('an added routine is removed with the same button', (tester) async {
    final api = await _pump(tester);
    await tester.tap(find.byKey(const Key('catalog-add-weekly_summary')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('catalog-add-weekly_summary')));
    await tester.pumpAndSettle();

    expect(api.deleted, ['r-weekly_summary']);
    expect(api.added, isEmpty);
  });

  testWidgets('a tap shows what it does and what it could say before adding it',
      (tester) async {
    final api = await _pump(tester);

    await tester.tap(find.text('Morning briefing'));
    await tester.pumpAndSettle();
    expect(find.text('Do the thing.'), findsOneWidget);
    expect(find.text('An example.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('catalog-sheet-add')));
    await tester.pumpAndSettle();
    expect(api.added.keys, ['morning_brief']);
  });

  testWidgets('one run after each conversation has no time to choose', (tester) async {
    await _pump(tester);
    await tester.scrollUntilVisible(find.text('Decisions after each meeting'), 200);
    await tester.tap(find.text('Decisions after each meeting'));
    await tester.pumpAndSettle();

    final when = tester.widget<ListTile>(find.byKey(const Key('catalog-time')));
    expect(when.trailing, isNull);
  });

  testWidgets('an assistant is added as it is, and once', (tester) async {
    final api = await _pump(tester, tab: CatalogTab.assistants);

    await tester.tap(find.byKey(const Key('catalog-add-assistant-work')));
    await tester.pumpAndSettle();

    expect(api.created.single.name, 'Work');
    expect(api.created.single.instructions, 'Work help. More.');
    expect(
      find.descendant(
          of: find.byKey(const Key('catalog-add-assistant-work')), matching: find.text('Added')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('catalog-add-assistant-work')));
    await tester.pumpAndSettle();
    expect(api.created, hasLength(1));
  });
}
