import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// "Continue with email": the account's email and password.
final class EmailSignInStep extends StatelessWidget {
  const EmailSignInStep({
    required this.emailController,
    required this.passwordController,
    required this.enabled,
    required this.onSubmit,
    super.key,
  });

  final TextEditingController emailController;
  final TextEditingController passwordController;
  final bool enabled;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Continue with email', style: textTheme.headlineLarge),
        const SizedBox(height: 8),
        Text(
          'Sign in with your Echo account.',
          style: textTheme.bodyMedium?.copyWith(color: palette.text2),
        ),
        const SizedBox(height: 28),
        TextField(
          key: const Key('sign-in-email'),
          controller: emailController,
          enabled: enabled,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('sign-in-password'),
          controller: passwordController,
          enabled: enabled,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.password],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => onSubmit(),
          decoration: const InputDecoration(labelText: 'Password'),
        ),
      ],
    );
  }
}
