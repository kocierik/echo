import 'package:flutter/material.dart';

import '../../services/app/app_runtime.dart';
import '../../services/device/phone_words.dart';
import '../../services/phone/phone_actions.dart';
import '../action_log_screen.dart';
import '../integrations_screen.dart';
import 'phone_apps_screen.dart';
import 'settings_components.dart';

class AutomationsSettingsScreen extends StatelessWidget {
  const AutomationsSettingsScreen({
    this.activityBuilder,
    this.integrationsBuilder,
    this.phoneActions,
    super.key,
  });

  final WidgetBuilder? activityBuilder;
  final WidgetBuilder? integrationsBuilder;

  /// The app's, unless injected; without one (tests) the row is hidden.
  final PhoneActionsService? phoneActions;

  @override
  Widget build(BuildContext context) {
    final phoneActions =
        this.phoneActions ?? AppRuntime.maybeCoordinator?.phoneActions;
    return SettingsPageScaffold(
      title: 'Automations',
      children: [
        const SettingsSection('AUTOMATIONS'),
        SettingsRow(
          icon: Icons.extension_outlined,
          title: 'Integrations',
          subtitle: 'Connect the apps Echo can act in.',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: integrationsBuilder ??
                  (_) => const IntegrationsScreen(),
            ),
          ),
        ),
        if (phoneActions != null)
          SettingsRow(
            icon: PhoneWords.isIPhone
                ? Icons.phone_iphone_rounded
                : Icons.phone_android_rounded,
            title: PhoneWords.onThisPhone,
            subtitle: PhoneWords.isIPhone
                ? 'Reminders and Calendar, for Echo to use.'
                : 'The calendar, for Echo to use.',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PhoneAppsScreen(phoneActions: phoneActions),
              ),
            ),
          ),
        SettingsRow(
          icon: Icons.history_rounded,
          title: 'Activity',
          subtitle: 'What Echo has done in your apps.',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: activityBuilder ?? (_) => const ActionLogScreen(),
            ),
          ),
        ),
      ],
    );
  }
}
