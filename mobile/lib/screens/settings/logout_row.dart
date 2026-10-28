import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/app/session_controller.dart';
import 'settings_components.dart';

/// "Log out", asked to confirm; while it runs a spinner, after a failed cleanup the
/// way to retry. Once logged out from this row, back to the first screen and
/// [onLoggedOut] (Profile and About both have one, and only one may navigate).
class LogoutRow extends StatefulWidget {
  const LogoutRow({
    required this.sessionController,
    required this.onLoggedOut,
    super.key,
  });

  final SessionController sessionController;
  final VoidCallback onLoggedOut;

  @override
  State<LogoutRow> createState() => _LogoutRowState();
}

class _LogoutRowState extends State<LogoutRow> {
  StreamSubscription<SessionState>? _subscription;
  late SessionState _state;
  bool _confirmedHere = false;

  @override
  void initState() {
    super.initState();
    _state = widget.sessionController.state;
    _subscription = widget.sessionController.stream.listen((state) {
      if (!mounted) return;
      setState(() => _state = state);
      if (state.loggedOut && _confirmedHere) {
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
    if (!confirmed) return;
    _confirmedHere = true;
    await widget.sessionController.logout();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
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
