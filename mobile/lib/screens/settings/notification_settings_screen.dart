import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/app/notification_scheduler.dart';
import '../../services/device/phone_words.dart';
import 'settings_components.dart';

/// Few notifications, each one switchable: briefings and promises on, the evening off.
final class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({
    required this.preferences,
    this.onChanged,
    super.key,
  });

  final SharedPreferences preferences;

  /// Called after a change, to reschedule with the new choice.
  final VoidCallback? onChanged;

  @override
  State<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

final class _NotificationSettingsScreenState extends State<NotificationSettingsScreen> {
  late final NotificationPreferences _choices = NotificationPreferences(widget.preferences);

  Future<void> _set(String key, bool value) async {
    await _choices.set(key, value);
    if (!mounted) return;
    setState(() {});
    widget.onChanged?.call();
  }

  Widget _row({
    required String key,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
  }) {
    return SettingsRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Switch(
        key: Key(key),
        value: value,
        onChanged: (on) => _set(key, on),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Notifications',
      children: [
        const SettingsSection('ONLY WHEN THERE IS SOMETHING TO DO'),
        _row(
          key: NotificationPreferences.briefingsKey,
          icon: Icons.event_note_outlined,
          title: 'Briefings',
          subtitle: 'Before a meeting: 10 minutes before, when you have tasks, a promise or a '
              'recent conversation with someone there. From Google Calendar, or from the '
              "${PhoneWords.phone}'s calendar (Profile → ${PhoneWords.onThisPhone}).\n"
              'When someone you know starts talking: Echo recognizes a voice you named and '
              'tells you at once what you promised each other and when you last talked. At '
              'most once every 4 hours for each person.',
          value: _choices.briefings,
        ),
        _row(
          key: NotificationPreferences.promisesKey,
          icon: Icons.handshake_outlined,
          title: 'Promises',
          subtitle: 'The morning a promise you made is due.',
          value: _choices.promises,
        ),
        _row(
          key: NotificationPreferences.eveningKey,
          icon: Icons.nightlight_outlined,
          title: 'Evening recap',
          subtitle: 'At 9 pm, after a day with conversations. The recap is on Today anyway.',
          value: _choices.evening,
        ),
        const SettingsMessage(
          'At most three a day, never between 10 pm and 8 am. They are scheduled on this '
          'phone while Echo is in use.',
        ),
        const SettingsSection('ON THE LOCK SCREEN'),
        if (PhoneWords.isIPhone)
          _row(
            key: NotificationPreferences.liveActivityKey,
            icon: Icons.phone_iphone_rounded,
            title: 'Live Activity',
            subtitle: 'Whether Echo is listening, its battery and the speech waiting to sync, '
                'on the Lock Screen and in the Dynamic Island.',
            value: _choices.liveActivity,
          )
        else
          // The foreground service (EchoStatusService.kt) cannot run without its notification
          const SettingsMessage(
            'While Echo is paired, a silent notification shows whether it is listening, its '
            'battery and the speech waiting to sync. Android needs it to keep Echo connected '
            'while the app is in the background.',
          ),
      ],
    );
  }
}
