import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/voice.dart';
import '../../services/api/api_exception.dart';
import '../../services/api/api_service.dart';
import '../../services/app/spoken_language.dart';
import '../../theme/app_theme.dart';
import 'settings_components.dart';

/// The text read aloud to record the user's voice (~20 s at a normal pace), in the
/// language they speak: reading a foreign text sounds unlike their voice.
/// No "Echo" in it: read aloud wearing Echo, the name would wake the voice assistant.
const enrollmentTexts = {
  'en': 'Hi, this is my voice. Today is a nice day and I have a lot to do: write a few '
      'emails, call a friend, buy some bread and maybe take a walk in the park. When I talk '
      'with the people around me, I want you to know when I am the one speaking and when '
      'someone else is.',
  'it': 'Ciao, questa è la mia voce. Oggi è una bella giornata e ho molte cose da '
      'fare: scrivere qualche email, chiamare un amico, comprare il pane e magari fare una '
      'passeggiata nel parco. Quando parlo con le persone intorno a me, voglio che tu '
      'sappia quando sto parlando io e quando parla qualcun altro.',
};

/// The text to read for [language]; English for any other.
String enrollmentTextFor(String? language) =>
    enrollmentTexts[language] ?? enrollmentTexts['en']!;

/// Known voices: the user's own, recorded here, and the people named in transcripts.
final class VoiceSettingsScreen extends StatefulWidget {
  const VoiceSettingsScreen({
    this.api,
    this.language,
    this.clock = DateTime.now,
    this.wait = Future<void>.delayed,
    super.key,
  });

  final VoiceApi? api;

  /// The language the user speaks: the text to read is in it.
  final String? language;
  final DateTime Function() clock;

  /// Between enrollment checks (injectable for tests).
  final Future<void> Function(Duration) wait;

  @override
  State<VoiceSettingsScreen> createState() => _VoiceSettingsScreenState();
}

final class _VoiceSettingsScreenState extends State<VoiceSettingsScreen> {
  late final VoiceApi _api;
  ApiService? _ownedApi;
  VoiceProfiles? _voices;
  String? _language;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? (_ownedApi = ApiService());
    _language = widget.language;
    if (_language == null) unawaited(_loadLanguage());
    unawaited(_load());
  }

  /// The language kept on the phone (Settings → Language), for the text to read.
  Future<void> _loadLanguage() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(SpokenLanguageStore.key);
      if (mounted && saved != null) setState(() => _language = saved);
    } catch (_) {}
  }

  @override
  void dispose() {
    _ownedApi?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final voices = await _api.getVoiceProfiles();
      if (!mounted) return;
      setState(() {
        _voices = voices;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = userMessage(error, 'Could not load the voices.');
        });
      }
    }
  }

  Future<void> _record() async {
    final learned = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => VoiceEnrollmentScreen(
        api: _api,
        language: _language,
        clock: widget.clock,
        wait: widget.wait,
      ),
    ));
    if (learned == true) await _load();
  }

  Future<void> _delete(VoiceProfile voice) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(voice.isSelf ? 'Delete your voice?' : 'Delete ${voice.name}\'s voice?'),
        content: const Text(
          'Echo forgets this voice fingerprint. Transcripts keep "You" and "Other".',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            key: const Key('voice-delete-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.deleteVoiceProfile(voice.id);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(userMessage(error, 'Could not delete the voice.'))),
        );
      }
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final voices = _voices;
    final own = voices?.own;
    return SettingsPageScaffold(
      title: 'Voices',
      children: [
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          SettingsRow(
            icon: Icons.error_outline_rounded,
            title: _error!,
            subtitle: 'Tap to retry.',
            onTap: () => unawaited(_load()),
          )
        else ...[
          if (voices?.fingerprintsEnabled == false)
            const SettingsRow(
              icon: Icons.info_outline_rounded,
              title: 'Voice recognition is off on the server',
              subtitle: 'Its voice model is not installed: rebuild the backend image.',
            ),
          const SettingsSection('YOUR VOICE'),
          SettingsRow(
            key: const Key('voice-own'),
            icon: own == null ? Icons.record_voice_over_outlined : Icons.verified_outlined,
            title: own == null ? 'Not recorded yet' : 'Recorded',
            subtitle: own == null
                ? 'Echo tells you apart by loudness only. Record your voice to do better.'
                : 'Learned from ${own.sampleCount} segment${own.sampleCount == 1 ? '' : 's'}. '
                    'Marking a line "Me" in a transcript improves it.',
          ),
          SettingsRow(
            key: const Key('voice-record'),
            icon: Icons.mic_none_rounded,
            title: own == null ? 'Record my voice' : 'Record again',
            onTap: voices?.fingerprintsEnabled == false ? null : () => unawaited(_record()),
          ),
          if (own != null)
            SettingsRow(
              key: const Key('voice-delete-own'),
              icon: Icons.delete_outline_rounded,
              title: 'Delete my voice',
              destructive: true,
              onTap: () => unawaited(_delete(own)),
            ),
          const SettingsSection('PEOPLE'),
          if (voices == null || voices.others.isEmpty)
            const SettingsRow(
              icon: Icons.people_outline_rounded,
              title: 'No voices yet',
              subtitle: 'Tap a speaker in a transcript to tell Echo who it is.',
            )
          else
            for (final voice in voices.others)
              SettingsRow(
                key: Key('voice-${voice.id}'),
                icon: Icons.person_outline_rounded,
                title: voice.name,
                subtitle: 'From ${voice.sampleCount} segment${voice.sampleCount == 1 ? '' : 's'}',
                trailing: IconButton(
                  key: Key('voice-delete-${voice.id}'),
                  tooltip: 'Delete ${voice.name}\'s voice',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => unawaited(_delete(voice)),
                ),
              ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Text(
              'Voice fingerprints stay on your server and are made only when you record or '
              'name a voice.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ],
    );
  }
}

/// Read a text aloud wearing Echo; then the server learns the voice from what it heard.
final class VoiceEnrollmentScreen extends StatefulWidget {
  const VoiceEnrollmentScreen({
    required this.api,
    this.language,
    this.clock = DateTime.now,
    this.wait = Future<void>.delayed,
    this.minimumReading = const Duration(seconds: 15),
    this.checks = 40,
    super.key,
  });

  final VoiceApi api;

  /// The language the user speaks: the text to read is in it (English by default).
  final String? language;
  final DateTime Function() clock;
  final Future<void> Function(Duration) wait;
  final Duration minimumReading;

  /// Enrollment checks, 3 s apart, before giving up.
  final int checks;

  @override
  State<VoiceEnrollmentScreen> createState() => _VoiceEnrollmentScreenState();
}

enum _Step { ready, reading, learning, done, failed }

final class _VoiceEnrollmentScreenState extends State<VoiceEnrollmentScreen> {
  _Step _step = _Step.ready;
  DateTime? _startedAt;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  String? _message;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _start() {
    setState(() {
      _step = _Step.reading;
      // A little before: the wearable's segment starts with the first word
      _startedAt = widget.clock().subtract(const Duration(seconds: 2));
      _elapsed = Duration.zero;
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  Future<void> _finish() async {
    _ticker?.cancel();
    setState(() => _step = _Step.learning);
    // The last words are still being sent by the wearable
    final endedAt = widget.clock().add(const Duration(seconds: 2));
    for (var check = 0; check < widget.checks; check++) {
      try {
        final result = await widget.api.enrollOwnVoice(_startedAt!, endedAt);
        if (!mounted) return;
        if (result.status == 'done') {
          setState(() {
            _step = _Step.done;
            _message = 'Echo learned your voice from ${result.segments} '
                'segment${result.segments == 1 ? '' : 's'}.';
          });
          return;
        }
        if (result.status == 'no_speech') {
          setState(() {
            _step = _Step.failed;
            _message = 'Echo heard nothing. Check that it is connected and listening, '
                'then try again.';
          });
          return;
        }
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _step = _Step.failed;
          _message = userMessage(error, 'Could not learn your voice.');
        });
        return;
      }
      await widget.wait(const Duration(seconds: 3));
    }
    if (mounted) {
      setState(() {
        _step = _Step.failed;
        _message = 'Echo is still processing what it heard. Try again in a minute.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final canFinish = _step == _Step.reading && _elapsed >= widget.minimumReading;
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(title: const Text('Record your voice')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            switch (_step) {
              _Step.ready => 'Wear Echo, check it is listening, then tap Start and read '
                  'this aloud in your normal voice.',
              _Step.reading => 'Read at your normal pace. ${_elapsed.inSeconds} s',
              _Step.learning => 'Learning your voice…',
              _Step.done || _Step.failed => _message ?? '',
            },
            key: const Key('enroll-status'),
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(AppTheme.panelRadius),
            ),
            child: Text(
              enrollmentTextFor(widget.language),
              style: textTheme.bodyLarge?.copyWith(fontSize: 18, height: 1.5),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Or say anything else for as long, in your own language: Echo only listens to how '
            'your voice sounds.',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          switch (_step) {
            _Step.ready => FilledButton(
                key: const Key('enroll-start'),
                onPressed: _start,
                child: const Text('Start'),
              ),
            _Step.reading => FilledButton(
                key: const Key('enroll-done'),
                onPressed: canFinish ? () => unawaited(_finish()) : null,
                child: const Text('Done'),
              ),
            _Step.learning => const Center(child: CircularProgressIndicator()),
            _Step.done => FilledButton(
                key: const Key('enroll-close'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Close'),
              ),
            _Step.failed => FilledButton(
                key: const Key('enroll-retry'),
                onPressed: () => setState(() => _step = _Step.ready),
                child: const Text('Try again'),
              ),
          },
        ],
      ),
    );
  }
}
