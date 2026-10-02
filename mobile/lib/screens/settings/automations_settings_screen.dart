import 'package:flutter/material.dart';

import '../integrations_screen.dart';
import '../rules_screen.dart';
import 'settings_components.dart';

class AutomationsSettingsScreen extends StatelessWidget {
  const AutomationsSettingsScreen({
    this.rulesBuilder,
    this.integrationsBuilder,
    super.key,
  });

  final WidgetBuilder? rulesBuilder;
  final WidgetBuilder? integrationsBuilder;

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Automations',
      children: [
        const SettingsSection('AUTOMATIONS'),
        SettingsRow(
          icon: Icons.account_tree_outlined,
          title: 'Rules',
          subtitle: 'Run actions when Echo recognizes something.',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: rulesBuilder ?? (_) => const RulesScreen(),
            ),
          ),
        ),
        SettingsRow(
          icon: Icons.extension_outlined,
          title: 'Integrations',
          subtitle: 'Connect services used by automation rules.',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: integrationsBuilder ??
                  (_) => const IntegrationsScreen(),
            ),
          ),
        ),
      ],
    );
  }
}