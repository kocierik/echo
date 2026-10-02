import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/segment.dart';
import '../models/transcript_group.dart';

abstract interface class TranscriptApi {
  Future<List<RecentSegment>> getRecentSegments({int limit = 50});
}

typedef TranscriptClock = DateTime Function();
typedef TranscriptDateLabelFormatter = String Function(DateTime day);
typedef TranscriptDebounceScheduler = void Function() Function(
  Duration delay,
  void Function() callback,
);

@immutable
final class TranscriptState {
  TranscriptState({
    required this.loading,
    required this.searching,
    required this.query,
    required this.error,
    required List<RecentSegment> allSegments,
    required List<TranscriptGroup> groups,
  })  : allSegments = List<RecentSegment>.unmodifiable(allSegments),
        groups = List<TranscriptGroup>.unmodifiable(groups);

  factory TranscriptState.initial() => TranscriptState(
        loading: true,
        searching: false,
        query: '',
        error: null,
        allSegments: const [],
        groups: const [],
      );

  final bool loading;
  final bool searching;
  final String query;
  final String? error;
  final List<RecentSegment> allSegments;
  final List<TranscriptGroup> groups;
}

final class TranscriptController extends ChangeNotifier {
  TranscriptController({
    required TranscriptApi api,
    TranscriptClock? clock,
    TranscriptDateLabelFormatter? dateLabelFormatter,
    TranscriptDebounceScheduler? debounceScheduler,
    Stream<Object?>? uploadStream,
  })  : _api = api,
        _clock = clock ?? DateTime.now,
        _dateLabelFormatter = dateLabelFormatter ?? _defaultDateLabel,
        _debounceScheduler = debounceScheduler ?? _scheduleTimer {
    _uploadSubscription = uploadStream?.listen((_) {
      unawaited(refresh());
    });
  }

  static const searchDelay = Duration(milliseconds: 300);
  static const fetchLimit = 100;

  final TranscriptApi _api;
  final TranscriptClock _clock;
  final TranscriptDateLabelFormatter _dateLabelFormatter;
  final TranscriptDebounceScheduler _debounceScheduler;

  TranscriptState _state = TranscriptState.initial();
  TranscriptState get state => _state;

  StreamSubscription<Object?>? _uploadSubscription;
  void Function()? _cancelDebounce;
  int _loadGeneration = 0;
  int _searchGeneration = 0;
  bool _initialized = false;
  bool _disposed = false;

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    _initialized = true;
    return _load(showLoading: true);
  }

  Future<void> load() => _load(showLoading: true);

  Future<void> refresh() => _load(showLoading: false);

  Future<void> refreshAfterDetail() => refresh();

  void setQuery(String value) {
    final query = value.trim();
    final generation = ++_searchGeneration;
    _cancelDebounce?.call();
    _cancelDebounce = null;

    if (query.isEmpty) {
      _emit(TranscriptState(
        loading: _state.loading,
        searching: false,
        query: '',
        error: _state.error,
        allSegments: _state.allSegments,
        groups: _group(_state.allSegments),
      ));
      return;
    }

    _emit(TranscriptState(
      loading: _state.loading,
      searching: true,
      query: query,
      error: _state.error,
      allSegments: _state.allSegments,
      groups: _state.groups,
    ));
    _cancelDebounce = _debounceScheduler(searchDelay, () {
      if (_disposed || generation != _searchGeneration) return;
      _cancelDebounce = null;
      _emit(TranscriptState(
        loading: _state.loading,
        searching: false,
        query: query,
        error: _state.error,
        allSegments: _state.allSegments,
        groups: _group(_filter(_state.allSegments, query)),
      ));
    });
  }

  Future<void> _load({required bool showLoading}) async {
    final generation = ++_loadGeneration;
    _emit(TranscriptState(
      loading: showLoading && _state.allSegments.isEmpty,
      searching: _state.searching,
      query: _state.query,
      error: null,
      allSegments: _state.allSegments,
      groups: _state.groups,
    ));

    try {
      final response = await _api.getRecentSegments(limit: fetchLimit);
      if (_disposed || generation != _loadGeneration) return;
      final segments = _dedupeAndSort(response);
      final visible = _state.query.isEmpty
          ? segments
          : _filter(segments, _state.query);
      _emit(TranscriptState(
        loading: false,
        searching: _state.searching,
        query: _state.query,
        error: null,
        allSegments: segments,
        groups: _group(visible),
      ));
    } catch (error) {
      if (_disposed || generation != _loadGeneration) return;
      _emit(TranscriptState(
        loading: false,
        searching: false,
        query: _state.query,
        error: error.toString().replaceFirst('Exception: ', ''),
        allSegments: _state.allSegments,
        groups: _state.groups,
      ));
    }
  }

  List<RecentSegment> _dedupeAndSort(List<RecentSegment> response) {
    final byId = <String, _IndexedSegment>{};
    for (var index = 0; index < response.length; index++) {
      byId.putIfAbsent(
        response[index].id,
        () => _IndexedSegment(index, response[index]),
      );
    }
    final indexed = byId.values.toList()
      ..sort((left, right) {
        final byTime = right.segment.recordedAt.compareTo(
          left.segment.recordedAt,
        );
        return byTime != 0 ? byTime : left.index.compareTo(right.index);
      });
    return indexed.map((item) => item.segment).toList(growable: false);
  }

  List<RecentSegment> _filter(
    List<RecentSegment> segments,
    String query,
  ) {
    final needle = query.toLowerCase();
    return segments.where((segment) {
      final text = _stripSpeakerPrefix(segment.text ?? '').toLowerCase();
      final speaker = _speakerSearchText(segment.speaker);
      return text.contains(needle) || speaker.contains(needle);
    }).toList(growable: false);
  }

  List<TranscriptGroup> _group(List<RecentSegment> segments) {
    final todayValue = _clock().toLocal();
    final today = DateTime(
      todayValue.year,
      todayValue.month,
      todayValue.day,
    );
    final yesterday = today.subtract(const Duration(days: 1));
    final byDay = <DateTime, List<RecentSegment>>{};
    for (final segment in segments) {
      final local = segment.recordedAt.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      byDay.putIfAbsent(day, () => []).add(segment);
    }

    return byDay.entries.map((entry) {
      final label = entry.key == today
          ? 'Today'
          : entry.key == yesterday
              ? 'Yesterday'
              : _dateLabelFormatter(entry.key);
      return TranscriptGroup(
        label: label,
        day: entry.key,
        items: entry.value,
      );
    }).toList(growable: false);
  }

  void _emit(TranscriptState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _loadGeneration++;
    _searchGeneration++;
    _cancelDebounce?.call();
    _cancelDebounce = null;
    unawaited(_uploadSubscription?.cancel());
    super.dispose();
  }

  static void Function() _scheduleTimer(
    Duration delay,
    void Function() callback,
  ) {
    final timer = Timer(delay, callback);
    return timer.cancel;
  }

  static String _defaultDateLabel(DateTime day) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[day.month - 1]} ${day.day}, ${day.year}';
  }

  static String _stripSpeakerPrefix(String text) {
    return text.replaceFirst(
      RegExp(r'^\[(Tu|Altri|You|Other)\]\s*', caseSensitive: false),
      '',
    );
  }

  static String _speakerSearchText(String? speaker) {
    return switch (speaker?.toLowerCase()) {
      'self' => 'self you tu',
      'other' => 'other others altri',
      'unknown' => 'unknown',
      final value? => value,
      null => '',
    };
  }
}

final class _IndexedSegment {
  const _IndexedSegment(this.index, this.segment);

  final int index;
  final RecentSegment segment;
}