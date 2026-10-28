import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/app/spoken_answers_store.dart';
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
  const SpokenAnswersScreen({required this.store, required this.onTry, super.key});

  final SpokenAnswersStore store;

  /// Says a sample sentence with the current choice.
  final Future<void> Function() onTry;

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
                SpokenAnswers.headphones =>
                  'Only when headphones or AirPods are connected; otherwise a notification.',
                SpokenAnswers.always => 'Also on the speaker. While the phone speaks, Echo '
                    'stops listening, so it does not record its own answer.',
              },
              style: textTheme.bodySmall?.copyWith(color: palette.text2),
            ),
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
