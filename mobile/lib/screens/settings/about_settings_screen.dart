import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/app/app_controller.dart';
import '../../services/app/session_controller.dart';
import 'settings_components.dart';

class AboutSettingsScreen extends StatefulWidget {
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
  State<AboutSettingsScreen> createState() => _AboutSettingsScreenState();
}

class _AboutSettingsScreenState extends State<AboutSettingsScreen> {
  StreamSubscription<SessionState>? _subscription;
  late SessionState _state;

  @override
  void initState() {
    super.initState();
    _state = widget.sessionController.state;
    _subscription = widget.sessionController.stream.listen((state) {
      if (!mounted) return;
      setState(() => _state = state);
      if (state.loggedOut) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        widget.onLoggedOut();
      }
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Log out of Echo?'),
            content: const Text(
              'This removes the API key, paired device identity, and local session preferences.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Log out'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed) await widget.sessionController.logout();
  }

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
        SettingsRow(
          icon: Icons.logout_rounded,
          title: _state.cleanupFailed ? 'Retry logout' : 'Log out',
          destructive: true,
          trailing: _state.loggingOut
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: _state.loggingOut ? null : _confirmLogout,
        ),
        if (_state.cleanupFailed)
          SettingsMessage(
            _state.error ?? 'Logout cleanup failed. Try again.',
            error: true,
            key: const Key('logout-cleanup-error'),
          ),
      ],
    );
  }
}