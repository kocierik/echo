import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// "Continue with email": the account's email and password, or a new account's.
final class EmailSignInStep extends StatefulWidget {
  const EmailSignInStep({
    required this.emailController,
    required this.passwordController,
    required this.enabled,
    required this.onSubmit,
    this.creatingAccount = false,
    this.onCreateAccount,
    this.onSignIn,
    super.key,
  });

  final TextEditingController emailController;
  final TextEditingController passwordController;
  final bool enabled;
  final VoidCallback onSubmit;

  /// Creating an account rather than signing in.
  final bool creatingAccount;

  /// Switch to creating an account (no link without it), and back.
  final VoidCallback? onCreateAccount;
  final VoidCallback? onSignIn;

  @override
  State<EmailSignInStep> createState() => _EmailSignInStepState();
}

final class _EmailSignInStepState extends State<EmailSignInStep> {
  bool _showPassword = false;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final creating = widget.creatingAccount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          creating ? 'Create your account' : 'Continue with email',
          style: textTheme.headlineLarge,
        ),
        const SizedBox(height: 8),
        Text(
          creating
              ? 'Your memories stay in your account, apart from anyone else\'s.'
              : 'Sign in with your Echo account.',
          style: textTheme.bodyMedium?.copyWith(color: palette.text2),
        ),
        const SizedBox(height: 28),
        TextField(
          key: const Key('sign-in-email'),
          controller: widget.emailController,
          enabled: widget.enabled,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('sign-in-password'),
          controller: widget.passwordController,
          enabled: widget.enabled,
          obscureText: !_showPassword,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: [
            creating ? AutofillHints.newPassword : AutofillHints.password
          ],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => widget.onSubmit(),
          decoration: InputDecoration(
            labelText: 'Password',
            helperText: creating ? 'At least 10 characters.' : null,
            suffixIcon: IconButton(
              key: const Key('sign-in-show-password'),
              tooltip: _showPassword ? 'Hide password' : 'Show password',
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(
                _showPassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        if (!creating)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('sign-in-forgot'),
              onPressed: () => _forgot(context),
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4)),
              child: const Text('Forgot your password?'),
            ),
          ),
        if (creating ? widget.onSignIn != null : widget.onCreateAccount != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: Key(
                  creating ? 'sign-in-have-account' : 'sign-in-create-account'),
              onPressed: widget.enabled
                  ? (creating ? widget.onSignIn : widget.onCreateAccount)
                  : null,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4)),
              child: Text(
                creating
                    ? 'Have an account? Sign in'
                    : 'New to Echo? Create an account',
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _forgot(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'For now, a password is reset by whoever runs your Echo server.',
                style: Theme.of(sheetContext).textTheme.bodyLarge,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.pop(sheetContext),
                child: const Text('OK'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
