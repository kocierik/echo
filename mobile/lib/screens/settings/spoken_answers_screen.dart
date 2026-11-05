import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/app/spoken_answers_store.dart';
import '../../services/app/spoken_voice_store.dart';
import '../../theme/app_theme.dart';
import 'settings_components.dart';

/// Profile's subtitle for the choice.
String spokenAnswersText(SpokenAnswers choice) => switch (choice) {
      SpokenAnswers.off => 'Off. Echo can read its answers aloud.',
      SpokenAnswers.headphones => 'In headphones only.',
      SpokenAnswers.always => 'Always, also on the speaker.',
    };

/// Spoken answers: whether the phone reads Echo's answers to what you asked aloud, and
/// "Try it".
final class SpokenAnswersScreen extends StatelessWidget {
  const SpokenAnswersScreen({
    required this.store,
    required this.onTry,
    this.voices,
    this.voiceStore,
    this.language = 'en',
    super.key,
  });

  final SpokenAnswersStore store;

  /// Says a sample sentence with the current choice.
  final Future<void> Function() onTry;

  /// The phone's voices and the one chosen ("Voice"; no row without them).
  final VoiceCatalog? voices;
  final SpokenVoiceStore? voiceStore;

  /// The language answers are read in ("it", "en").
  final String language;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return ValueListenableBuilder<SpokenAnswers>(
      valueListenable: store,
      builder: (context, choice, _) => SettingsPageScaffold(
        title: 'Spoken answers',
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Text(
              'When you ask Echo something aloud, the phone reads the answer to you, '
              'also with the screen locked.',
              style: textTheme.bodyMedium?.copyWith(color: palette.text2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SegmentedButton<SpokenAnswers>(
              key: const Key('spoken-answers-control'),
              segments: const [
                ButtonSegment(value: SpokenAnswers.off, label: Text('Off')),
                ButtonSegment(
                  value: SpokenAnswers.headphones,
                  icon: Icon(Icons.headphones_outlined),
                  label: Text('Headphones'),
                ),
                ButtonSegment(
                  value: SpokenAnswers.always,
                  icon: Icon(Icons.volume_up_outlined),
                  label: Text('Always'),
                ),
              ],
              selected: {choice},
              onSelectionChanged: (selection) => unawaited(store.set(selection.single)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              switch (choice) {
                SpokenAnswers.off => 'Answers come as notifications, as now.',
                SpokenAnswers.headphones => 'Only when headphones or AirPods are connected; '
                    'otherwise a notification. While the phone speaks, Echo stops listening.',
                SpokenAnswers.always => 'Also on the speaker. While the phone speaks, Echo '
                    'stops listening, so it does not record its own answer.',
              },
              style: textTheme.bodySmall?.copyWith(color: palette.text2),
            ),
          ),
          if ((voices, voiceStore) case (final voices?, final voiceStore?))
            ListenableBuilder(
              listenable: voiceStore,
              builder: (context, _) => SettingsGroup(children: [
                SettingsRow(
                  key: const Key('spoken-answers-voice'),
                  icon: Icons.graphic_eq_rounded,
                  title: 'Voice',
                  value: voiceStore.voiceFor(language)?.name ?? "The phone's",
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => VoicePickerScreen(
                        voices: voices,
                        store: voiceStore,
                        language: language,
                        onTry: onTry,
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextButton.icon(
                key: const Key('spoken-answers-try'),
                onPressed: () => unawaited(onTry()),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Try it'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Spoken answers → Voice: the voices the phone has for the language, better ones first;
/// a tap chooses one and says the sample with it.
final class VoicePickerScreen extends StatefulWidget {
  const VoicePickerScreen({
    required this.voices,
    required this.store,
    required this.language,
    required this.onTry,
    super.key,
  });

  final VoiceCatalog voices;
  final SpokenVoiceStore store;
  final String language;
  final Future<void> Function() onTry;

  @override
  State<VoicePickerScreen> createState() => _VoicePickerScreenState();
}

final class _VoicePickerScreenState extends State<VoicePickerScreen> {
  List<PhoneVoice>? _voices;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final voices = await widget.voices.voices(widget.language);
    if (mounted) setState(() => _voices = voices);
  }

  Future<void> _choose(PhoneVoice? voice) async {
    await widget.store.choose(widget.language, voice);
    if (mounted) setState(() {});
    await widget.onTry();
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final chosen = widget.store.voiceFor(widget.language);
    final voices = _voices;
    Widget mark(bool on) => on
        ? Icon(Icons.check_rounded, color: palette.accent)
        : const SizedBox(width: 24);
    return SettingsPageScaffold(
      title: 'Voice',
      children: [
        if (voices == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          SettingsRow(
            key: const Key('voice-default'),
            icon: Icons.phone_iphone_rounded,
            title: "The phone's",
            subtitle: 'Its own voice for the language.',
            trailing: mark(chosen == null),
            onTap: () => unawaited(_choose(null)),
          ),
          for (final voice in voices)
            SettingsRow(
              key: Key('voice-${voice.name}-${voice.locale}'),
              icon: Icons.record_voice_over_outlined,
              title: voice.name,
              subtitle: voice.detail,
              trailing: mark(voice == chosen),
              onTap: () => unawaited(_choose(voice)),
            ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Text(
            'For a more natural voice, download an Enhanced or Premium one in Settings → '
            'Accessibility → Spoken Content → Voices: it then shows here.',
            style: textTheme.bodySmall?.copyWith(color: palette.text2),
          ),
        ),
      ],
    );
  }
}
