import 'package:flutter/material.dart';

import '../../services/app/app_controller.dart';
import '../../services/app/session_controller.dart';
import 'logout_row.dart';
import 'settings_components.dart';

class AboutSettingsScreen extends StatelessWidget {
  const AboutSettingsScreen({
    required this.appController,
    required this.sessionController,
    required this.onLoggedOut,
    super.key,
  });

  final AppController appController;
  final SessionController sessionController;
  final VoidCallback onLoggedOut;

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'About',
      children: [
        const SettingsSection('APP'),
        const SettingsRow(
          icon: Icons.info_outline_rounded,
          title: 'Version',
          value: '0.1.0',
        ),
        SettingsRow(
          icon: Icons.description_outlined,
          title: 'Licenses',
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Echo',
            applicationVersion: '0.1.0',
          ),
        ),
        const SettingsSection('ACCOUNT'),
        LogoutRow(sessionController: sessionController, onLoggedOut: onLoggedOut),
      ],
    );
  }
}
