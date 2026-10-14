import 'dart:async';

import 'package:echo_app/models/memory.dart';
import 'package:echo_app/services/memories_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

void main() {
  final day = DateTime.utc(2026, 10, 14, 9);

  List<ConversationCard> cards(int count) => [
        for (var i = 0; i < count; i++)
          card('c$i', startedAt: day.subtract(Duration(hours: i))),
      ];

  test('loads the first page and pages on demand', () async {
    final api = FakeMemoryApi(conversations: cards(5));
    final controller = MemoriesController(api: api, pageSize: 2);
    addTearDown(controller.dispose);

    await controller.initialize();
    expect(controller.state.conversations.map((c) => c.id), ['c0', 'c1']);
    expect(controller.state.hasMore, isTrue);

    await controller.loadMore();
    await controller.loadMore();
    expect(controller.state.conversations.length, 5);
    expect(controller.state.hasMore, isFalse);
    expect(api.calls, ['list 2 0', 'list 2 2', 'list 2 4']);

    await controller.loadMore();
    expect(api.calls.length, 3); // nothing more to load
  });

  test('a refresh keeps the list on screen and reports failures', () async {
    final api = FakeMemoryApi(conversations: cards(1));
    final controller = MemoriesController(api: api);
    addTearDown(controller.dispose);
    await controller.initialize();

    api.listError = serverError('Offline');
    await controller.refresh();

    expect(controller.state.conversations.length, 1);
    expect(controller.state.error, 'Offline');
    expect(controller.state.loading, isFalse);
  });

  test('new segments refresh the list', () async {
    final uploads = StreamController<Object?>();
    addTearDown(uploads.close);
    final api = FakeMemoryApi(conversations: cards(1));
    final controller = MemoriesController(api: api, uploadStream: uploads.stream);
    addTearDown(controller.dispose);
    await controller.initialize();

    uploads.add(null);
    await pumpEventQueue();

    expect(api.calls.where((c) => c.startsWith('list')).length, 2);
  });

  group('search', () {
    late List<void Function()> scheduled;

    MemoriesController controllerFor(FakeMemoryApi api) {
      scheduled = [];
      final controller = MemoriesController(
        api: api,
        debounceScheduler: (delay, callback) {
          scheduled.add(callback);
          return () => scheduled.remove(callback);
        },
      );
      addTearDown(controller.dispose);
      return controller;
    }

    test('waits for the debounce and searches the server once', () async {
      final api = FakeMemoryApi()
        ..searchResults = MemorySearchResults(
          conversations: [card('hit', startedAt: day)],
          entities: const [],
        );
      final controller = controllerFor(api);

      controller.setQuery('at');
      controller.setQuery(' atlas ');
      expect(controller.state.searching, isTrue);
      expect(controller.state.query, 'atlas');
      expect(scheduled.length, 1); // the first one was cancelled

      scheduled.single();
      await pumpEventQueue();

      expect(api.calls, ['search atlas']);
      expect(controller.state.searching, isFalse);
      expect(controller.state.results!.conversations.single.id, 'hit');
    });

    test('a one-letter query is not a search', () async {
      final controller = controllerFor(FakeMemoryApi());

      controller.setQuery('a');

      expect(controller.state.isSearching, isFalse);
      expect(scheduled, isEmpty);
    });

    test('clearing drops results and a stale answer is ignored', () async {
      final api = FakeMemoryApi()..gate = Completer<void>();
      final controller = controllerFor(api);
      controller.setQuery('atlas');
      scheduled.single();

      controller.setQuery('');
      api.gate!.complete();
      await pumpEventQueue();

      expect(controller.state.isSearching, isFalse);
      expect(controller.state.results, isNull);
    });

    test('a failed search says why', () async {
      final api = FakeMemoryApi()..searchError = serverError('Search down');
      final controller = controllerFor(api);

      controller.setQuery('atlas');
      scheduled.single();
      await pumpEventQueue();

      expect(controller.state.searchError, 'Search down');
      expect(controller.state.searching, isFalse);
    });
  });
}
