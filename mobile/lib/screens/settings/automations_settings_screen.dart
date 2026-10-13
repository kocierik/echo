import 'package:flutter/material.dart';

import '../action_log_screen.dart';
import '../integrations_screen.dart';
import 'settings_components.dart';

class AutomationsSettingsScreen extends StatelessWidget {
  const AutomationsSettingsScreen({
    this.activityBuilder,
    this.integrationsBuilder,
    super.key,
  });

  final WidgetBuilder? activityBuilder;
  final WidgetBuilder? integrationsBuilder;

  @override
  Widget build(BuildContext context) {
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
