import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/api/api_exception.dart';
import '../../services/app/session_controller.dart';
import 'settings_components.dart';
import '../navigation.dart';

/// Thrown by [DeleteAccountRow.deleteAccount] when the person backed out of confirming
/// with Google: nothing was deleted and nothing went wrong.
final class DeletionCancelled implements Exception {
  const DeletionCancelled();
}

/// "Delete account": the password (or Google, for an account made with it) confirms it,
/// then everything Echo keeps of the account is deleted on the server and this phone is
/// signed out, back to the first screen.
class DeleteAccountRow extends StatelessWidget {
  const DeleteAccountRow({
    required this.sessionController,
    required this.deleteAccount,
    required this.onLoggedOut,
    this.withGoogle = false,
    super.key,
  });

  final SessionController sessionController;

  /// Deletes the account on the server; a refused confirmation is an [ApiException] 403.
  /// The password is null when [withGoogle]: the callee asks Google.
  final Future<void> Function(String? password) deleteAccount;
  final VoidCallback onLoggedOut;

  /// The account has no password: Google confirms instead.
  final bool withGoogle;

  Future<void> _confirm(BuildContext context) async {
    final deleted = await showDialog<bool>(
          context: context,
          builder: (_) =>
              _DeleteAccountDialog(deleteAccount: deleteAccount, withGoogle: withGoogle),
        ) ??
        false;
    if (!deleted || !context.mounted) return;
    // The account and this phone's key are gone on the server: the phone forgets them too
    await sessionController.logout();
    if (!context.mounted) return;
    popToTabs(context);
    onLoggedOut();
  }

  @override
  Widget build(BuildContext context) => SettingsRow(
        icon: Icons.delete_forever_outlined,
        title: 'Delete account',
        subtitle: 'Your conversations, voice, people and photos, for good.',
        destructive: true,
        onTap: () => _confirm(context),
      );
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog({required this.deleteAccount, required this.withGoogle});

  final Future<void> Function(String? password) deleteAccount;
  final bool withGoogle;

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _password = TextEditingController();
  bool _deleting = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  // shortcut: in the browser Google confirms only through its own button; an account
  // made with Google is deleted from the iPhone app until that button is here too
  bool get _googleHere => !kIsWeb;

  Future<void> _delete() async {
    if (!widget.withGoogle && _password.text.isEmpty) {
      setState(() => _error = 'Enter your password.');
      return;
    }
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      await widget.deleteAccount(widget.withGoogle ? null : _password.text);
      if (mounted) Navigator.pop(context, true);
    } on DeletionCancelled {
      if (mounted) setState(() => _deleting = false);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _error = error.statusCode != 403
            ? 'Echo could not delete the account. Try again.'
            : widget.withGoogle
                ? 'Google did not confirm this account.'
                : 'Wrong password.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _error = 'Echo could not delete the account. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Delete your account?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Everything Echo keeps of you is deleted: conversations and their audio, '
            'voices, people, photos, notes and chats. It cannot be undone.',
          ),
          const SizedBox(height: 16),
          if (!widget.withGoogle)
            TextField(
              key: const Key('delete-account-password'),
              controller: _password,
              obscureText: true,
              enabled: !_deleting,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(labelText: 'Password', errorText: _error),
              onSubmitted: (_) => _delete(),
            )
          else
            Text(
              _error ??
                  (_googleHere
                      ? 'Google confirms it is you.'
                      : 'You signed up with Google: delete the account from the iPhone app.'),
              key: const Key('delete-account-google'),
              style: TextStyle(
                color: _error != null ? Theme.of(context).colorScheme.error : null,
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _deleting ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('delete-account-confirm'),
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: _deleting || (widget.withGoogle && !_googleHere) ? null : _delete,
          child: _deleting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Delete'),
        ),
      ],
    );
  }
}
