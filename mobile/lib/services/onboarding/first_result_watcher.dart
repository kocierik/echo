import 'dart:async';

import 'package:clock/clock.dart' as time;
import 'package:flutter/foundation.dart';

import '../api/actions_api.dart';
import '../chat/voice_updates_service.dart';

@immutable
final class FirstResultState {
  const FirstResultState({this.heard, this.answer, this.gaveUp = false});

  /// The request Echo is answering ("Echo, remind me to …").
  final String? heard;

  /// Echo's answer to it.
  final String? answer;

  /// No answer within the patience: it will be on Today.
  final bool gaveUp;
}

/// The first run's last screen: watches for the first voice request the user makes,
/// then for its answer, for a while.
final class FirstResultWatcher extends ValueNotifier<FirstResultState> {
  FirstResultWatcher({
    required VoiceWorkingApi working,
    required VoiceUpdatesApi updates,
    this.poll = const Duration(seconds: 2),
    this.patience = const Duration(seconds: 30),
    DateTime Function()? clock,
    VoidCallback? onDispose,
  })  : _working = working,
        _updates = updates,
        // The package clock: tests move it with fake time
        _clock = clock ?? time.clock.now,
        _onDispose = onDispose,
        super(const FirstResultState());

  /// Closes what the watcher was given to own (its API client).
  final VoidCallback? _onDispose;

  final VoiceWorkingApi _working;
  final VoiceUpdatesApi _updates;
  final Duration poll;
  final Duration patience;
  final DateTime Function() _clock;

  Timer? _timer;
  DateTime? _startedAt;

  /// Answers after this moment, in the server's time (the phone's clock may differ).
  DateTime? _since;
  bool _checking = false;
  bool _disposed = false;

  Future<void> start() async {
    if (_startedAt != null) return;
    _startedAt = _clock();
    try {
      _since = (await _updates.getVoiceUpdates(null)).now;
    } catch (_) {
      _since = _clock().toUtc();
    }
    if (_disposed) return;
    _timer = Timer.periodic(poll, (_) => unawaited(_check()));
  }

  Future<void> _check() async {
    if (_checking || _disposed) return;
    _checking = true;
    try {
      final working = await _working.getVoiceWorking();
      final request = working.where((item) => !item.isPhoto).firstOrNull;
      if (!_disposed && request != null && value.heard == null) {
        value = FirstResultState(heard: request.text);
      }
      final updates = await _updates.getVoiceUpdates(_since);
      final answer = updates.messages.firstOrNull;
      if (!_disposed && answer != null) {
        value = FirstResultState(heard: value.heard, answer: answer.content);
        _timer?.cancel();
        return;
      }
    } catch (_) {
      // Not reachable right now: the next check tries again
    } finally {
      _checking = false;
    }
    if (_disposed) return;
    if (_clock().difference(_startedAt!) >= patience) {
      value = FirstResultState(heard: value.heard, gaveUp: true);
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _onDispose?.call();
    super.dispose();
  }
}
