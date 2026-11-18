import 'package:flutter/material.dart';

import '../navigation.dart';
import '../../services/device/phone_words.dart';
import 'settings_components.dart';

/// What Echo can do, with examples: the chat ones open Ask with the question.
final class CapabilitiesScreen extends StatelessWidget {
  const CapabilitiesScreen({this.onAsk, this.onOpenVoices, super.key});

  final AskCallback? onAsk;
  final VoidCallback? onOpenVoices;

  static const _askExamples = [
    'What did I promise this week?',
    'What did Marco say about the quote?',
    'What do I have tomorrow?',
    'How much did I spend this week?',
    'Summarize my latest emails',
  ];

  static const _voiceExamples = [
    'Hey Echo, remind me to call Giulia on Friday',
    'Hey Echo, every morning at 7 tell me the weather in Milan',
    'Hey Echo, what is this?',
    'Hey Echo, remember where I parked',
    'Hey Echo, send Marco a message on Slack',
  ];

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SettingsPageScaffold(
      title: 'What Echo can do',
      children: [
        const SettingsSection('REMEMBERS'),
        const SettingsMessage(
          'Wear it: Echo keeps what is said as conversations, with their people, events '
          'and your promises, a summary for every day and every week. To-dos are the '
          'ones you ask for. What needs to be live, like the weather or the news, it '
          'looks up on the web.',
        ),
        const SettingsSection('ASK IN THE CHAT (TAP ONE)'),
        const SettingsMessage(
          'In any language: Echo understands it and answers in the one you use.',
        ),
        for (final question in _askExamples)
          SettingsRow(
            key: Key('capability-ask-$question'),
            icon: Icons.chat_bubble_outline_rounded,
            title: question,
            onTap: onAsk == null
                ? null
                : () {
                    popToTabs(context);
                    onAsk!(question);
                  },
          ),
        const SettingsSection('SAY IT TO THE WEARABLE'),
        for (final command in _voiceExamples)
          SettingsRow(icon: Icons.record_voice_over_outlined, title: command),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Text(
            'The answer arrives in Ask, in your thread with Echo, with a notification. Reading '
            'and creating run at once; sending to others, changing and deleting wait for '
            'your Confirm. Reminders and events go to your connected apps, or to this '
            "${PhoneWords.phone}'s (Profile → ${PhoneWords.onThisPhone}).",
            style: textTheme.bodySmall,
          ),
        ),
        const SettingsSection('SEES AND HEARS WHO'),
        const SettingsRow(
          icon: Icons.photo_camera_outlined,
          title: 'Photos',
          subtitle: 'A short press of the wearable button, or 📷 in Ask: Echo answers about '
              'what you see and remembers it. A business card becomes a person.',
        ),
        const SettingsRow(
          icon: Icons.bookmark_outline_rounded,
          title: 'Saved',
          subtitle: '"Echo, save this": a wine, a book, a receipt, where you parked. Echo '
              'keeps it with its moment in a list (Today → Saved) and finds it again.',
        ),
        SettingsRow(
          icon: Icons.mic_none_rounded,
          title: 'Who is speaking',
          subtitle: 'Record your voice, then tap a speaker in a transcript to name them.',
          onTap: onOpenVoices,
        ),
        const SettingsRow(
          icon: Icons.person_pin_outlined,
          title: 'Who is in front of you',
          subtitle: 'When Marco starts talking, your phone tells you what you promised him '
              'and when you last talked. From the voices you named.',
        ),
        const SettingsRow(
          icon: Icons.notifications_none_rounded,
          title: 'Comes to you, rarely',
          subtitle: 'Before a meeting, when someone you know starts talking and on the day '
              'of a promise. At most three a day.',
        ),
      ],
    );
  }
}
