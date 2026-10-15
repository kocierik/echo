import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/memory.dart';
import '../../models/person.dart';
import '../api/api_exception.dart';
import '../api/api_service.dart';

typedef DebounceScheduler = void Function() Function(
  Duration delay,
  void Function() callback,
);

@immutable
final class MemoriesState {
  const MemoriesState({
    this.conversations = const [],
    this.loading = true,
    this.loadingMore = false,
    this.hasMore = false,
    this.error,
    this.query = '',
    this.searching = false,
    this.results,
    this.searchError,
    this.people = const [],
    this.peopleLoaded = false,
    this.peopleLoading = false,
    this.peopleError,
  });

  final List<ConversationCard> conversations;

  /// First load with nothing to show yet.
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final String? error;

  /// Trimmed search text; empty when not searching.
  final String query;
  final bool searching;
  final MemorySearchResults? results;
  final String? searchError;

  final List<PersonSummary> people;

  /// People were asked for at least once (they load when first shown).
  final bool peopleLoaded;
  final bool peopleLoading;
  final String? peopleError;

  bool get isSearching => query.isNotEmpty;

  MemoriesState copyWith({
    List<ConversationCard>? conversations,
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    String? Function()? error,
    String? query,
    bool? searching,
    MemorySearchResults? Function()? results,
    String? Function()? searchError,
    List<PersonSummary>? people,
    bool? peopleLoaded,
    bool? peopleLoading,
    String? Function()? peopleError,
  }) {
    return MemoriesState(
      conversations: conversations ?? this.conversations,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: error == null ? this.error : error(),
      query: query ?? this.query,
      searching: searching ?? this.searching,
      results: results == null ? this.results : results(),
      searchError: searchError == null ? this.searchError : searchError(),
      people: people ?? this.people,
      peopleLoaded: peopleLoaded ?? this.peopleLoaded,
      peopleLoading: peopleLoading ?? this.peopleLoading,
      peopleError: peopleError == null ? this.peopleError : peopleError(),
    );
  }
}

/// The Memories list: conversations newest first, loaded a page at a time,
/// and server-side search over the whole memory.
final class MemoriesController extends ChangeNotifier {
  MemoriesController({
    required MemoryApi api,
    Stream<Object?>? uploadStream,
    DebounceScheduler? debounceScheduler,
    this.pageSize = 30,
  })  : _api = api,
        _debounce = debounceScheduler ?? _timer {
    // A new Segment can start or extend a conversation: refresh the first page
    _uploadSubscription = uploadStream?.listen((_) => unawaited(refresh()));
  }

  static const searchDelay = Duration(milliseconds: 350);
  static const minQueryLength = 2;

  final MemoryApi _api;
  final DebounceScheduler _debounce;
  final int pageSize;

  MemoriesState _state = const MemoriesState();
  MemoriesState get state => _state;

  StreamSubscription<Object?>? _uploadSubscription;
  void Function()? _cancelSearch;
  int _loadGeneration = 0;
  int _searchGeneration = 0;
  int _peopleGeneration = 0;
  bool _initialized = false;
  bool _disposed = false;

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    _initialized = true;
    return refresh();
  }

  /// Reloads the first page, keeping what is on screen until it arrives.
  Future<void> refresh() async {
    final generation = ++_loadGeneration;
    _emit(_state.copyWith(
      loading: _state.conversations.isEmpty,
      error: () => null,
    ));
    try {
      final page = await _api.listConversations(limit: pageSize);
      if (!_current(generation)) return;
      _emit(_state.copyWith(
        conversations: page,
        loading: false,
        loadingMore: false,
        hasMore: page.length == pageSize,
      ));
    } catch (error) {
      if (!_current(generation)) return;
      _emit(_state.copyWith(
        loading: false,
        error: () => userMessage(error, 'Could not load your memories.'),
      ));
    }
    if (_state.isSearching) unawaited(_search(_state.query, ++_searchGeneration));
    if (_state.peopleLoaded) unawaited(loadPeople());
  }

  /// Loads everyone Echo heard about; called when People is first shown.
  Future<void> loadPeople() async {
    final generation = ++_peopleGeneration;
    _emit(_state.copyWith(
      peopleLoaded: true,
      peopleLoading: _state.people.isEmpty,
      peopleError: () => null,
    ));
    try {
      final people = await _api.listPeople();
      if (_disposed || generation != _peopleGeneration) return;
      _emit(_state.copyWith(people: people, peopleLoading: false));
    } catch (error) {
      if (_disposed || generation != _peopleGeneration) return;
      _emit(_state.copyWith(
        peopleLoading: false,
        peopleError: () => userMessage(error, 'Could not load people.'),
      ));
    }
  }

  Future<void> loadMore() async {
    if (_state.loading || _state.loadingMore || !_state.hasMore) return;
    final generation = _loadGeneration;
    _emit(_state.copyWith(loadingMore: true));
    try {
      final page = await _api.listConversations(
        limit: pageSize,
        offset: _state.conversations.length,
      );
      if (!_current(generation)) return;
      final known = {for (final c in _state.conversations) c.id};
      _emit(_state.copyWith(
        conversations: [
          ..._state.conversations,
          ...page.where((c) => !known.contains(c.id)),
        ],
        loadingMore: false,
        hasMore: page.length == pageSize,
      ));
    } catch (error) {
      if (!_current(generation)) return;
      _emit(_state.copyWith(
        loadingMore: false,
        error: () => userMessage(error, 'Could not load more memories.'),
      ));
    }
  }

  void setQuery(String value) {
    final query = value.trim();
    final generation = ++_searchGeneration;
    _cancelSearch?.call();
    _cancelSearch = null;
    if (query.length < minQueryLength) {
      // Too short to search: back to the list
      _emit(_state.copyWith(
        query: '',
        searching: false,
        results: () => null,
        searchError: () => null,
      ));
      return;
    }
    _emit(_state.copyWith(query: query, searching: true, searchError: () => null));
    _cancelSearch = _debounce(searchDelay, () {
      _cancelSearch = null;
      unawaited(_search(query, generation));
    });
  }

  Future<void> _search(String query, int generation) async {
    try {
      final results = await _api.search(query);
      if (_disposed || generation != _searchGeneration) return;
      _emit(_state.copyWith(searching: false, results: () => results));
    } catch (error) {
      if (_disposed || generation != _searchGeneration) return;
      _emit(_state.copyWith(
        searching: false,
        searchError: () => userMessage(error, 'Search failed.'),
      ));
    }
  }

  bool _current(int generation) => !_disposed && generation == _loadGeneration;

  void _emit(MemoriesState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelSearch?.call();
    unawaited(_uploadSubscription?.cancel());
    super.dispose();
  }

  static void Function() _timer(Duration delay, void Function() callback) {
    final timer = Timer(delay, callback);
    return timer.cancel;
  }
}
