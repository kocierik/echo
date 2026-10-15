import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/phone/phone_actions.dart';
import '../../services/phone/phone_calendar.dart';
import 'settings_components.dart';

/// Settings → Automations → On this iPhone: Reminders and Calendar for Echo.
final class PhoneAppsScreen extends StatefulWidget {
  const PhoneAppsScreen({required this.phoneActions, this.openSettings, super.key});

  final PhoneActionsService phoneActions;

  /// Opens Echo's page in iOS Settings (injected in tests).
  final Future<void> Function()? openSettings;

  @override
  State<PhoneAppsScreen> createState() => _PhoneAppsScreenState();
}

final class _PhoneAppsScreenState extends State<PhoneAppsScreen> {
  final _access = <PhoneApp, PhoneAccess>{};
  final _busy = <PhoneApp>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    for (final app in PhoneApp.values) {
      final access = await widget.phoneActions.access(app);
      if (!mounted) return;
      setState(() => _access[app] = access);
    }
  }

  Future<void> _set(PhoneApp app, bool on) async {
    setState(() => _busy.add(app));
    final access = await widget.phoneActions.setOn(app, on);
    if (!mounted) return;
    setState(() {
      _busy.remove(app);
      _access[app] = access;
    });
  }

  Future<void> _openSettings() async {
    final open = widget.openSettings;
    if (open != null) return open();
    await launchUrl(Uri.parse('app-settings:'));
  }

  Widget _row(PhoneApp app, {required IconData icon, required String subtitle}) {
    final name = app == PhoneApp.reminders ? 'Reminders' : 'Calendar';
    final access = _access[app];
    return SettingsRow(
      icon: icon,
      title: name,
      subtitle: subtitle,
      trailing: Switch(
        key: Key('phone-app-${app.name}'),
        value: widget.phoneActions.isOn(app) && access == PhoneAccess.granted,
        onChanged: access == null ||
                access == PhoneAccess.unavailable ||
                _busy.contains(app)
            ? null
            : (on) => unawaited(_set(app, on)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final denied = PhoneApp.values
        .where((app) => _access[app] == PhoneAccess.denied)
        .map((app) => app == PhoneApp.reminders ? 'Reminders' : 'Calendar')
        .toList();
    final unavailable = _access.values.contains(PhoneAccess.unavailable);
    return SettingsPageScaffold(
      title: 'On this iPhone',
      children: [
        const SettingsMessage(
          'Echo can add reminders and events to the apps of this iPhone when you ask, '
          'by voice or in Ask, and read what is in them. A reminder with a time '
          'alerts you on the iPhone; a meeting in the calendar gets its briefing.',
        ),
        const SettingsSection('APPS'),
        _row(
          PhoneApp.reminders,
          icon: Icons.checklist_rounded,
          subtitle: '"Echo, remind me to call Ada at 6"',
        ),
        _row(
          PhoneApp.calendar,
          icon: Icons.calendar_today_outlined,
          subtitle: '"Echo, put dinner with Marco on Friday at 8"',
        ),
        if (denied.isNotEmpty) ...[
          SettingsMessage(
            '${denied.join(' and ')}: Echo is not allowed. Allow it in iOS Settings.',
            error: true,
            key: const Key('phone-apps-denied'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: OutlinedButton(
              onPressed: () => unawaited(_openSettings()),
              child: const Text('Open iOS Settings'),
            ),
          ),
        ],
        if (unavailable)
          const SettingsMessage(
            'Reminders and Calendar are not available on this device.',
            error: true,
          ),
        const SettingsMessage(
          'They run on this iPhone: Echo reaches them while the app is running, as it '
          'is while the wearable is connected.',
        ),
      ],
    );
  }
}
