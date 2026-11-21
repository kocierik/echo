import 'package:flutter/material.dart';

import '../../services/app/app_controller.dart';
import '../../services/app/session_controller.dart';
import 'delete_account_row.dart';
import 'logout_row.dart';
import 'settings_components.dart';

class AboutSettingsScreen extends StatelessWidget {
  const AboutSettingsScreen({
    required this.appController,
    required this.sessionController,
    required this.onLoggedOut,
    this.deleteAccount,
    this.deleteWithGoogle = false,
    this.more = const [],
    super.key,
  });

  final AppController appController;
  final SessionController sessionController;
  final VoidCallback onLoggedOut;

  /// Deletes the account on the server; without it the row is not shown.
  /// The password is null for an account made with Google ([deleteWithGoogle]).
  final Future<void> Function(String? password)? deleteAccount;

  /// The account has no password: Google confirms the deletion.
  final bool deleteWithGoogle;

  /// Pages opened once in a while (examples, diagnostics, the server), after the app's.
  final List<Widget> more;

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
        if (more.isNotEmpty) ...[
          const SettingsSection('MORE'),
          ...more,
        ],
        const SettingsSection('ACCOUNT'),
        LogoutRow(sessionController: sessionController, onLoggedOut: onLoggedOut),
        if (deleteAccount case final delete?)
          DeleteAccountRow(
            sessionController: sessionController,
            deleteAccount: delete,
            onLoggedOut: onLoggedOut,
            withGoogle: deleteWithGoogle,
          ),
      ],
    );
  }
}
