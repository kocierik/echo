import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/device_status.dart';
import '../../utils/spoken_text.dart';
import '../app/spoken_answers_store.dart';
import '../device/device_controller.dart';

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

  /// Echo is muted for the answer being spoken: [recover] waits for its end.
  bool _muting = false;

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
  /// stays until that works. Nothing while an answer is spoken: it unmutes at its end.
  Future<void> recover() async {
    if (_muting) return;
    await _unmute();
  }

  Future<void> _unmute() async {
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
    _muting = mute;
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
      _muting = false;
      if (muted) {
        await _unmute();
      } else if (mute) {
        await _preferences.remove(mutedKey);
      }
    }
  }
}

/// The phone's own text-to-speech. Done when the answer is said, stopped or failed (iOS
/// does not end an awaited speak that is stopped, so the plugin's handlers end it);
/// other audio is lowered meanwhile.
final class FlutterTtsVoice implements AnswerVoice {
  FlutterTtsVoice([FlutterTts? tts]) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  Completer<void>? _done;
  bool _ready = false;

  Future<void> _prepare() async {
    if (_ready) return;
    void finish([dynamic _]) {
      final done = _done;
      if (done != null && !done.isCompleted) done.complete();
    }

    _tts
      ..setCompletionHandler(finish)
      ..setCancelHandler(finish)
      ..setErrorHandler(finish);
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _tts.setSharedInstance(true);
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [
          IosTextToSpeechAudioCategoryOptions.duckOthers,
          IosTextToSpeechAudioCategoryOptions.interruptSpokenAudioAndMixWithOthers,
        ],
        IosTextToSpeechAudioMode.voicePrompt,
      );
    }
    _ready = true;
  }

  @override
  Future<void> speak(String text, String language) async {
    await _prepare();
    await _tts.setLanguage(language == 'it' ? 'it-IT' : 'en-US');
    final done = _done = Completer<void>();
    await _tts.speak(text);
    // Never longer than a slow reading of it: a lost callback must not stop the line
    await done.future.timeout(
      Duration(seconds: 15 + text.length ~/ 8),
      onTimeout: () {},
    );
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
    final done = _done;
    if (done != null && !done.isCompleted) done.complete();
  }
}

/// Headphones from the native "echo/device" channel (AppDelegate.swift, EchoEngine.kt).
final class ChannelAudioOutput implements AudioOutput {
  const ChannelAudioOutput();

  static const _channel = MethodChannel('echo/device');

  @override
  Future<bool> headphones() async =>
      await _channel.invokeMethod<bool>('headphones') ?? false;
}

/// The wearable, through its controller.
final class DeviceEchoMic implements EchoMic {
  const DeviceEchoMic(this._device);

  final DeviceController _device;

  @override
  bool get listening => _device.state.connectionState == DeviceConnectionState.listening;

  @override
  Future<void> setMuted(bool muted) => _device.setMuted(muted);
}
