import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/action_models.dart';
import '../../models/chat_session.dart';
import '../app/notification_service.dart';

/// The slice of [ApiService] needed to poll for voice answers.
abstract interface class VoiceUpdatesApi {
  Future<VoiceUpdates> getVoiceUpdates(DateTime? since);
}

/// Checks for new answers in the thread with Echo, and for routine runs that found
/// something or could not run, and shows a local notification for each. Called on every
/// segment upload and on app resume.
final class VoiceUpdatesService {
  VoiceUpdatesService(
    this._api,
    this._notifications,
    this._preferences, {
    void Function()? onNewMessages,
    void Function()? onNewRuns,
    void Function(String answer)? onNewAnswer,
  })  : _onNewMessages = onNewMessages,
        _onNewRuns = onNewRuns,
        _onNewAnswer = onNewAnswer;

  /// Called once per check that found new answers: Ask reloads the thread.
  final void Function()? _onNewMessages;

  /// Called once per check that found new routine runs: Today and Ask reload them.
  final void Function()? _onNewRuns;

  /// Each new answer, whole, as it is notified: Spoken answers reads it aloud.
  final void Function(String answer)? _onNewAnswer;

  static const lastSeenKey = 'voice_updates_last_seen';
  static const seenKeysKey = 'voice_updates_seen_keys';
  static const maxSeenKeys = 50;
  static const overlap = Duration(seconds: 60);

  final VoiceUpdatesApi _api;
  final NotificationService _notifications;
  final SharedPreferences _preferences;
  Future<void>? _inFlight;
  int _counter = 0;

  /// Concurrent calls share a single request. Never throws.
  Future<void> check() {
    return _inFlight ??= _run().whenComplete(() => _inFlight = null);
  }

  Future<void> _run() async {
    try {
      final stored = _preferences.getString(lastSeenKey);
      final lastSeen = stored == null ? null : DateTime.tryParse(stored);
      final updates = await _api.getVoiceUpdates(
        lastSeen?.subtract(overlap),
      );
      if (lastSeen != null) {
        final seen = List<String>.of(
          _preferences.getStringList(seenKeysKey) ?? const <String>[],
        );
        var found = false;
        for (final message in updates.messages) {
          if (message.role != 'assistant') continue;
          final key = _keyOf(message);
          if (seen.contains(key)) continue;
          await _notifications.showVoiceAnswer(
            _preview(message.content),
            sessionId: message.sessionId,
            id: _nextId(),
          );
          _onNewAnswer?.call(message.content);
          seen.add(key);
          found = true;
          if (seen.length > maxSeenKeys) {
            seen.removeRange(0, seen.length - maxSeenKeys);
          }
          await _preferences.setStringList(seenKeysKey, seen);
        }
        if (found) _onNewMessages?.call();
        var foundRuns = false;
        for (final run in updates.routineRuns) {
          final key = 'run:${run.id}';
          if (seen.contains(key)) continue;
          await _notifications.showRoutineRun(
            run.status == 'failed'
                ? 'A routine could not run'
                : _preview(run.text ?? ''),
            runId: run.id,
            id: _nextId(),
          );
          seen.add(key);
          foundRuns = true;
          if (seen.length > maxSeenKeys) {
            seen.removeRange(0, seen.length - maxSeenKeys);
          }
          await _preferences.setStringList(seenKeysKey, seen);
        }
        if (foundRuns) _onNewRuns?.call();
      }
      await _preferences.setString(
        lastSeenKey,
        updates.now.toUtc().toIso8601String(),
      );
    } catch (_) {
      // Swallow: lastSeen is not advanced, so the next wake retries.
    }
  }

  int _nextId() =>
      NotificationService.voiceAnswerBaseId +
      (_counter++ % NotificationService.voiceAnswerIdCount);

  static String _keyOf(ChatSessionMessage message) {
    final stamp = message.timestamp?.toUtc().toIso8601String() ??
        'n:${message.content.hashCode}';
    return '${message.sessionId ?? ''}|$stamp';
  }

  static String _preview(String content) {
    const limit = 120;
    if (content.length <= limit) return content;
    return '${content.substring(0, limit)}…';
  }
}
