import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/spoken_text.dart';
import '../app/spoken_answers_store.dart';

/// The phone's voice: speaks [text] in [language] ("it" or "en"), done when it is said or
/// stopped.
abstract interface class AnswerVoice {
  Future<void> speak(String text, String language);
  Future<void> stop();
}

/// Where the phone's sound goes.
abstract interface class AudioOutput {
  /// Headphones, AirPods or another Bluetooth audio output; false when unknown.
  Future<bool> headphones();
}

/// Echo's microphone, muted while the phone speaks on its speaker.
abstract interface class EchoMic {
  /// Connected and recording.
  bool get listening;
  Future<void> setMuted(bool muted);
}

/// Reads Echo's answers aloud as Profile → Spoken answers says: one after the other, as
/// plain speech in the user's language. On the speaker Echo is muted while the phone
/// speaks, so it does not record its own answer, and listens again after; a flag kept
/// on the phone lets [recover] unmute it if the app died in between. Never throws.
final class AnswerSpeaker {
  AnswerSpeaker({
    required AnswerVoice voice,
    required AudioOutput output,
    required ValueListenable<SpokenAnswers> setting,
    required SharedPreferences preferences,
    required String Function() language,
    EchoMic? mic,
  })  : _voice = voice,
        _output = output,
        _setting = setting,
        _preferences = preferences,
        _language = language,
        _mic = mic;

  /// Set while Echo is muted for an answer.
  static const mutedKey = 'spoken_answers_muted_echo';

  final AnswerVoice _voice;
  final AudioOutput _output;
  final ValueListenable<SpokenAnswers> _setting;
  final SharedPreferences _preferences;
  final String Function() _language;
  final EchoMic? _mic;

  /// The answers in line; each starts once the one before is done.
  Future<void> _line = Future.value();

  /// Bumped by [stop]: the answers waiting in line are dropped.
  int _generation = 0;

  /// Speaks [answer] after the ones before it, when the setting allows.
  Future<void> say(String answer) => _enqueue((generation) async {
        final choice = _setting.value;
        if (choice == SpokenAnswers.off) return;
        final headphones = await _headphones();
        if (choice == SpokenAnswers.headphones && !headphones) return;
        final language = _language();
        await _speak(spokenText(answer, language: language), language, headphones, generation);
      });

  /// "Try it": a sample sentence, whatever the setting.
  Future<void> sample() => _enqueue((generation) async {
        final language = _language();
        final text = language == 'it'
            ? 'Ciao, sono Echo. Ti leggerò le risposte così.'
            : "Hi, I'm Echo. This is how I'll read you my answers.";
        await _speak(text, language, await _headphones(), generation);
      });

  /// Stops the answer being spoken and drops the ones waiting.
  Future<void> stop() async {
    _generation++;
    try {
      await _voice.stop();
    } catch (_) {}
  }

  /// Unmutes Echo when an answer left it muted (the app died while speaking); the flag
  /// stays until that works.
  Future<void> recover() async {
    final mic = _mic;
    if (mic == null || _preferences.getBool(mutedKey) != true) return;
    try {
      await mic.setMuted(false);
      await _preferences.remove(mutedKey);
    } catch (_) {}
  }

  Future<void> _enqueue(Future<void> Function(int generation) speak) {
    final generation = _generation;
    final next = _line.then((_) async {
      if (generation != _generation) return;
      try {
        await speak(generation);
      } catch (_) {}
    });
    _line = next;
    return next;
  }

  Future<bool> _headphones() async {
    try {
      return await _output.headphones();
    } catch (_) {
      return false;
    }
  }

  Future<void> _speak(String text, String language, bool headphones, int generation) async {
    if (text.isEmpty || generation != _generation) return;
    final mic = _mic;
    // In headphones Echo cannot hear it; a muted Echo is the user's choice
    final mute = mic != null && !headphones && mic.listening;
    var muted = false;
    try {
      if (mute) {
        await _preferences.setBool(mutedKey, true);
        await mic.setMuted(true);
        muted = true;
      }
      await _voice.speak(text, language);
    } catch (_) {
      // The answer is still in Ask and in the notification
    } finally {
      if (muted) {
        await recover();
      } else if (mute) {
        await _preferences.remove(mutedKey);
      }
    }
  }
}
