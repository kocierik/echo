import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../api/speech_api.dart';
import '../app/spoken_voice_store.dart';
import 'answer_speaker.dart';

/// Plays an answer's MP3, done when it is heard to the end or stopped.
abstract interface class AudioPlayback {
  Future<void> play(Uint8List mp3);
  Future<void> stop();
}

/// Spoken answers in Echo's natural voice (Plus, Unlimited: [SpokenVoiceStore.premium])
/// when one is chosen: the server makes the audio, the phone plays it. With none chosen,
/// without the plan, offline or on any failure, the [phone]'s voice reads it instead:
/// an answer is never lost to the network.
final class NaturalVoice implements AnswerVoice {
  NaturalVoice({
    required SpeechApi api,
    required AnswerVoice phone,
    required SpokenVoiceStore store,
    AudioPlayback? playback,
  })  : _api = api,
        _phone = phone,
        _store = store,
        _playback = playback ?? JustAudioPlayback();

  final SpeechApi _api;
  final AnswerVoice _phone;
  final SpokenVoiceStore _store;
  final AudioPlayback _playback;

  /// Bumped by [stop]: audio still on its way is not played.
  int _generation = 0;

  @override
  Future<void> speak(String text, String language) async {
    final voice = _store.naturalVoice;
    if (voice == null) return _phone.speak(text, language);
    final generation = _generation;
    final Uint8List mp3;
    try {
      mp3 = await _api.speak(text, voice);
    } catch (_) {
      // Offline, the plan changed, the server could not: the phone's voice
      if (generation != _generation) return;
      return _phone.speak(text, language);
    }
    if (generation != _generation) return;
    try {
      // Never longer than a slow reading: a lost end must not keep Echo muted
      await _playback.play(mp3).timeout(Duration(seconds: 15 + text.length ~/ 8));
    } catch (_) {
      await _playback.stop();
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    await _playback.stop();
    await _phone.stop();
  }
}

/// just_audio, with other sound lowered (not paused) while it speaks.
final class JustAudioPlayback implements AudioPlayback {
  AudioPlayer? _player;
  bool _configured = false;

  Future<void> _configure() async {
    if (_configured) return;
    final session = await AudioSession.instance;
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.duckOthers |
          AVAudioSessionCategoryOptions.interruptSpokenAudioAndMixWithOthers,
      avAudioSessionMode: AVAudioSessionMode.voicePrompt,
      androidAudioAttributes: const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.assistant,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
    ));
    _configured = true;
  }

  @override
  Future<void> play(Uint8List mp3) async {
    await _configure();
    final file = File('${(await getTemporaryDirectory()).path}/echo-answer.mp3');
    await file.writeAsBytes(mp3, flush: true);
    final player = _player ??= AudioPlayer();
    await player.setFilePath(file.path);
    final session = await AudioSession.instance;
    await session.setActive(true);
    try {
      // Done when heard to the end, or stopped
      await player.play();
    } finally {
      await session.setActive(false);
    }
  }

  @override
  Future<void> stop() async {
    await _player?.stop();
  }
}
