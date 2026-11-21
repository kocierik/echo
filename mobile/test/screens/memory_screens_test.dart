import 'package:echo_app/models/memory_items.dart';
import 'package:echo_app/models/person.dart';
import 'package:echo_app/screens/settings/about_you_screen.dart';
import 'package:echo_app/screens/settings/documents_screen.dart';
import 'package:echo_app/screens/people_screen.dart';
import 'package:echo_app/services/api/api_exception.dart';
import 'package:echo_app/services/api/memory_items_api.dart';
import 'package:echo_app/services/memory/memories_controller.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

final class _Memory implements AboutYouApi, DocumentsApi {
  List<UserFact> kept = [
    UserFact(id: 'f1', text: 'Lavora come sviluppatore a Milano', status: 'kept',
        source: 'you', noted: DateTime(2026, 3, 12)),
  ];
  List<UserFact> suggestions = [
    const UserFact(id: 's1', text: 'Gioca a padel il giovedì', status: 'suggested',
        source: 'conversation'),
  ];
  List<UserDocument> documents = [];
  final uploaded = <String>[];
  final deleted = <String>[];
  String? refuseUpload;

  @override
  Future<UserFacts> getFacts() async => UserFacts(kept: kept, suggestions: suggestions);

  @override
  Future<UserFact> addFact(String text) async {
    final fact = UserFact(id: 'n${kept.length}', text: text, status: 'kept', source: 'you');
    kept = [...kept, fact];
    return fact;
  }

  @override
  Future<UserFact> editFact(String id, String text) async {
    final fact = UserFact(id: id, text: text, status: 'kept', source: 'you');
    kept = [for (final f in kept) f.id == id ? fact : f];
    return fact;
  }

  @override
  Future<UserFact> keepFact(String id) async {
    final fact = suggestions.firstWhere((f) => f.id == id);
    suggestions = suggestions.where((f) => f.id != id).toList();
    final kept0 = UserFact(id: id, text: fact.text, status: 'kept', source: fact.source);
    kept = [...kept, kept0];
    return kept0;
  }

  @override
  Future<void> deleteFact(String id) async {
    deleted.add(id);
    kept = kept.where((f) => f.id != id).toList();
    suggestions = suggestions.where((f) => f.id != id).toList();
  }

  @override
  Future<List<UserDocument>> listDocuments() async => documents;

  @override
  Future<UserDocument> uploadDocument(String filename, List<int> bytes) async {
    if (refuseUpload != null) {
      throw ApiException(statusCode: 422, code: 'http', message: refuseUpload!, retryable: false);
    }
    uploaded.add(filename);
    final document = UserDocument(
      id: 'd${documents.length}', title: filename, kind: 'pdf', sizeBytes: bytes.length,
      status: 'processing', wordCount: 10,
    );
    documents = [document, ...documents];
    return document;
  }

  @override
  Future<UserDocument> getDocument(String id) async {
    final document = documents.firstWhere((d) => d.id == id);
    return UserDocument(
      id: document.id, title: document.title, kind: document.kind,
      sizeBytes: document.sizeBytes, status: document.status, wordCount: document.wordCount,
      pages: document.pages, preview: 'Il canone è di 900 euro al mese.',
    );
  }

  @override
  Future<void> deleteDocument(String id) async {
    deleted.add(id);
    documents = documents.where((d) => d.id != id).toList();
  }
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 1200);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light, home: screen));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('People has a Map action that opens the map', (tester) async {
    final controller = MemoriesController(api: FakeMemoryApi());
    addTearDown(controller.dispose);
    var opened = false;

    await _pump(tester, PeopleScreen(
      controller: controller,
      onOpenPerson: (_) async {},
      onOpenMap: () async {
        opened = true;
      },
      now: DateTime(2026, 11, 10),
    ));

    final mapAction = find.byKey(const Key('people-map'));
    expect(mapAction, findsOneWidget);
    expect(find.descendant(of: mapAction, matching: find.text('Map')), findsOneWidget);
    await tester.tap(mapAction);
    await tester.pumpAndSettle();
    expect(opened, isTrue);
  });

  testWidgets('at 2.0 text scale People does not overflow', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final api = FakeMemoryApi()
      ..people = [
        const PersonSummary(
            id: 'p1',
            name: 'Alessandra Bianchi-Montefiore',
            role: 'architect and neighbour',
            conversationCount: 12,
            openTaskCount: 3),
        const PersonSummary(id: 'p2', name: 'Marco Rossi', conversationCount: 1),
      ];
    final controller = MemoriesController(api: api);
    addTearDown(controller.dispose);
    await _pump(tester, PeopleScreen(
      controller: controller,
      onOpenPerson: (_) async {},
      onOpenMap: () async {},
      now: DateTime(2026, 11, 10),
    ));
    expect(find.text('Marco Rossi'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('People: with no one yet it says to add them, and Add person adds one',
      (tester) async {
    final api = FakeMemoryApi();
    final controller = MemoriesController(api: api);
    addTearDown(controller.dispose);

    await _pump(tester, PeopleScreen(
      controller: controller,
      onOpenPerson: (_) async {},
      onOpenMap: () async {},
      now: DateTime(2026, 11, 12),
    ));

    // Only people added here are kept from what Echo hears
    expect(find.textContaining('Add the people you want Echo to remember'), findsOneWidget);
    await tester.tap(find.byKey(const Key('people-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('people-add-name')), '  Marco Rossi ');
    await tester.tap(find.byKey(const Key('people-add-confirm')));
    await tester.pumpAndSettle();

    expect(api.calls, contains('add person Marco Rossi'));
    // The list is asked again, to show them
    expect(api.calls.where((call) => call == 'people').length, 2);
  });

  group('About you', () {
    testWidgets('the kept facts and what Echo noticed, kept with a tap', (tester) async {
      final api = _Memory();
      await _pump(tester, AboutYouScreen(api: api));

      expect(find.text('Lavora come sviluppatore a Milano'), findsOneWidget);
      expect(find.text('Noted 12 March 2026'), findsOneWidget); // an old one may have changed
      expect(find.text('Gioca a padel il giovedì'), findsOneWidget);

      await tester.tap(find.byKey(const Key('fact-keep-s1')));
      await tester.pumpAndSettle();

      expect(api.suggestions, isEmpty);
      expect(api.kept.map((f) => f.text), contains('Gioca a padel il giovedì'));
      expect(find.byKey(const Key('fact-keep-s1')), findsNothing);
    });

    testWidgets('a suggestion says it was heard in a conversation', (tester) async {
      await _pump(tester, AboutYouScreen(api: _Memory()));

      expect(find.text('Heard in a conversation'), findsOneWidget);
    });

    testWidgets('a suggestion discarded is gone', (tester) async {
      final api = _Memory();
      await _pump(tester, AboutYouScreen(api: api));

      await tester.tap(find.byKey(const Key('fact-discard-s1')));
      await tester.pumpAndSettle();

      expect(api.deleted, ['s1']);
      expect(find.text('Gioca a padel il giovedì'), findsNothing);
    });

    testWidgets('a fact is added, edited and deleted', (tester) async {
      final api = _Memory();
      await _pump(tester, AboutYouScreen(api: api));

      await tester.tap(find.byKey(const Key('facts-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('fact-text')), 'Ha due figli');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Ha due figli'), findsOneWidget);

      await tester.tap(find.text('Ha due figli'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('fact-text')), 'Ha tre figli');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Ha tre figli'), findsOneWidget);

      await tester.tap(find.byKey(const Key('fact-delete-f1')));
      await tester.pumpAndSettle();
      expect(find.text('Lavora come sviluppatore a Milano'), findsNothing);
    });
  });

  group('Documents', () {
    testWidgets('a picked file is uploaded and shown while Echo indexes it', (tester) async {
      final api = _Memory();
      await _pump(tester, DocumentsScreen(
        api: api,
        pick: () async => (name: 'Contratto.pdf', bytes: [1, 2, 3]),
        pollInterval: const Duration(seconds: 1),
      ));
      expect(find.textContaining('No documents yet'), findsOneWidget);

      await tester.tap(find.byKey(const Key('documents-add')));
      await tester.pumpAndSettle();

      expect(api.uploaded, ['Contratto.pdf']);
      expect(find.text('Contratto.pdf'), findsOneWidget);
      expect(find.textContaining('Reading it'), findsOneWidget);

      api.documents = [
        const UserDocument(id: 'd0', title: 'Contratto.pdf', kind: 'pdf', sizeBytes: 3,
            status: 'ready', wordCount: 10, pages: 2),
      ];
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 pages'), findsOneWidget);
    });

    testWidgets('a file over 10 MB is never sent', (tester) async {
      final api = _Memory();
      await _pump(tester, DocumentsScreen(
        api: api,
        pick: () async => throw const DocumentTooLarge(),
      ));

      await tester.tap(find.byKey(const Key('documents-add')));
      await tester.pumpAndSettle();

      expect(api.uploaded, isEmpty);
      expect(find.textContaining('At most 10 MB'), findsOneWidget);
    });

    testWidgets('a refused file says why', (tester) async {
      final api = _Memory()..refuseUpload = 'No text found in it';
      await _pump(tester, DocumentsScreen(
        api: api,
        pick: () async => (name: 'scan.pdf', bytes: [1]),
      ));

      await tester.tap(find.byKey(const Key('documents-add')));
      await tester.pumpAndSettle();

      expect(find.textContaining('No text found in it'), findsOneWidget);
    });

    testWidgets('a document shows its beginning and can be deleted', (tester) async {
      final api = _Memory()
        ..documents = [
          const UserDocument(id: 'd0', title: 'Contratto.pdf', kind: 'pdf',
              sizeBytes: 2500000, status: 'ready', wordCount: 10, pages: 2),
        ];
      await _pump(tester, DocumentsScreen(api: api, pick: () async => null));

      await tester.tap(find.text('Contratto.pdf'));
      await tester.pumpAndSettle();
      expect(find.text('Il canone è di 900 euro al mese.'), findsOneWidget);
      expect(find.textContaining('2.4 MB'), findsOneWidget);

      await tester.tap(find.byKey(const Key('document-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();

      expect(api.deleted, ['d0']);
      expect(find.text('Contratto.pdf'), findsNothing);
    });

    testWidgets('a failed document says why', (tester) async {
      final api = _Memory()
        ..documents = [
          const UserDocument(id: 'd0', title: 'x.pdf', kind: 'pdf', sizeBytes: 3,
              status: 'failed', wordCount: 1, error: 'Echo could not index it.'),
        ];
      await _pump(tester, DocumentsScreen(api: api, pick: () async => null));

      expect(find.textContaining('Echo could not index it.'), findsOneWidget);
    });
  });
}
