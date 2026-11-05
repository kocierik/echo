import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/device_status.dart';
import '../../utils/spoken_text.dart';
import '../app/spoken_answers_store.dart';
import '../app/spoken_voice_store.dart';
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
/// plain speech in the user's language, never while the user dictates. Echo is muted
/// while the phone speaks, so it does not record its own answer (headphones cannot be
/// told from a car or a Bluetooth speaker), and listens again after; a flag kept on the
/// phone lets [recover] unmute it if the app died in between. Never throws.
final class AnswerSpeaker {
  AnswerSpeaker({
    required AnswerVoice voice,
    required AudioOutput output,
    required ValueListenable<SpokenAnswers> setting,
    required SharedPreferences preferences,
    required String Function() language,
    EchoMic? mic,
    ValueListenable<bool>? quiet,
  })  : _voice = voice,
        _output = output,
        _setting = setting,
        _preferences = preferences,
        _language = language,
        _mic = mic,
        _quiet = quiet;

  /// Set while Echo is muted for an answer.
  static const mutedKey = 'spoken_answers_muted_echo';

  final AnswerVoice _voice;
  final AudioOutput _output;
  final ValueListenable<SpokenAnswers> _setting;
  final SharedPreferences _preferences;
  final String Function() _language;
  final EchoMic? _mic;

  /// True while the user dictates in Ask: an answer then is left to the notification.
  final ValueListenable<bool>? _quiet;

  /// The answers in line; each starts once the one before is done.
  Future<void> _line = Future.value();

  /// Bumped by [stop]: the answers waiting in line are dropped.
  int _generation = 0;

  /// Echo is muted for the answer being spoken: [recover] waits for its end.
  bool _muting = false;

  /// The device's last state, for [deviceSeen].
  DeviceConnectionState? _lastSeen;

  /// A sample is waiting or being spoken: another "Try it" tap adds nothing.
  bool _sampling = false;

  /// Speaks [answer] after the ones before it, when the setting allows.
  Future<void> say(String answer) => _enqueue((generation) async {
        final choice = _setting.value;
        if (choice == SpokenAnswers.off || (_quiet?.value ?? false)) return;
        if (choice == SpokenAnswers.headphones && !await _headphones()) return;
        final language = _language();
        await _speak(spokenText(answer, language: language), language, generation);
      });

  /// "Try it": a sample sentence, whatever the setting; once, however many taps.
  Future<void> sample() {
    if (_sampling) return Future.value();
    _sampling = true;
    return _enqueue((generation) async {
      final language = _language();
      final text = language == 'it'
          ? 'Ciao, sono Echo. Ti leggerò le risposte così.'
          : "Hi, I'm Echo. This is how I'll read you my answers.";
      await _speak(text, language, generation);
    }).whenComplete(() => _sampling = false);
  }

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

  /// Echo's state as the device reports it. Muted with the flag set: an answer left it
  /// so. Listening on a working connection (not the guess made on connecting, before
  /// its telemetry): nothing is left to recover, and a later mute is the user's own.
  Future<void> deviceSeen(DeviceConnectionState state) async {
    final before = _lastSeen;
    _lastSeen = state;
    if (_muting) return;
    if (state == DeviceConnectionState.muted) {
      await _unmute();
    } else if (state == DeviceConnectionState.listening &&
        (before == DeviceConnectionState.listening || before == DeviceConnectionState.muted)) {
      await _preferences.remove(mutedKey);
    }
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

  Future<void> _speak(String text, String language, int generation) async {
    if (text.isEmpty || generation != _generation) return;
    final mic = _mic;
    // A muted Echo is the user's choice
    final mute = mic != null && mic.listening;
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
/// other audio is lowered meanwhile (iOS: a ducking session; Android: audio focus).
/// A stopped answer's cancel can come late: the next answer waits for it briefly, so
/// it cannot end that one.
final class FlutterTtsVoice implements AnswerVoice, VoiceCatalog {
  FlutterTtsVoice([FlutterTts? tts, this._chosen]) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  /// The voice chosen for a language (Profile → Spoken answers → Voice); none: the
  /// phone's own.
  final PhoneVoice? Function(String language)? _chosen;
  Completer<void>? _done;

  /// Set by [stop]: the engine's report of that cancel, still to come.
  Completer<void>? _draining;
  bool _ready = false;

  Future<void> _prepare() async {
    if (_ready) return;
    void finish([dynamic _]) {
      final draining = _draining;
      if (draining != null && !draining.isCompleted) {
        draining.complete();
        return;
      }
      final done = _done;
      if (done != null && !done.isCompleted) done.complete();
    }

    _tts
      ..setCompletionHandler(finish)
      ..setCancelHandler(finish)
      ..setErrorHandler(finish);
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // The category first: the session then starts mixable, lowering music, not pausing it
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [
          IosTextToSpeechAudioCategoryOptions.duckOthers,
          IosTextToSpeechAudioCategoryOptions.interruptSpokenAudioAndMixWithOthers,
        ],
        IosTextToSpeechAudioMode.voicePrompt,
      );
      await _tts.setSharedInstance(true);
    }
    _ready = true;
  }

  /// Never longer than a slow reading of [text]: a lost callback or a platform call that
  /// never answers must not keep Echo muted, and the voice is stopped then.
  @override
  Future<void> speak(String text, String language) async {
    var late = false;
    await _say(text, language).timeout(
      Duration(seconds: 15 + text.length ~/ 8),
      onTimeout: () => late = true,
    );
    if (late) {
      try {
        await _tts.stop().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  Future<void> _say(String text, String language) async {
    await _prepare();
    final draining = _draining;
    if (draining != null) {
      await draining.future.timeout(const Duration(milliseconds: 500), onTimeout: () {});
      _draining = null;
    }
    await _tts.setLanguage(language == 'it' ? 'it-IT' : 'en-US');
    if (_chosen?.call(language) case final voice?) {
      try {
        // A voice deleted from the phone since: the language's own speaks
        await _tts.setVoice(voice.toTts());
      } catch (_) {}
    }
    final done = _done = Completer<void>();
    // 1 when it started; anything else (Android without a working engine): no callback
    final started = await _tts.speak(
      text,
      focus: defaultTargetPlatform == TargetPlatform.android,
    );
    if (started != 1) return;
    await done.future;
  }

  @override
  Future<List<PhoneVoice>> voices(String language) async {
    final List<dynamic> raw;
    try {
      raw = await _tts.getVoices as List<dynamic>? ?? const [];
    } catch (_) {
      return const [];
    }
    final found = <PhoneVoice>{
      for (final item in raw)
        if (PhoneVoice.fromMap(item) case final voice?
            when voice.locale.toLowerCase().startsWith(language.toLowerCase()))
          voice,
    }.toList()
      ..sort((a, b) {
        final byRank = a.rank.compareTo(b.rank);
        return byRank != 0 ? byRank : a.name.compareTo(b.name);
      });
    return found;
  }

  @override
  Future<void> stop() async {
    final done = _done;
    final speaking = done != null && !done.isCompleted;
    if (speaking) _draining = Completer<void>();
    await _tts.stop();
    if (speaking) done.complete();
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
