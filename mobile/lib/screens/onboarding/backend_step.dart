import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

final class BackendStep extends StatelessWidget {
  const BackendStep({
    required this.serverController,
    required this.apiKeyController,
    required this.enabled,
    super.key,
  });

  final TextEditingController serverController;
  final TextEditingController apiKeyController;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.dns_outlined, size: 32, color: palette.blue),
        const SizedBox(height: 24),
        Text('Connect your backend', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        Text(
          'Echo sends encrypted requests to the server you control.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: palette.text2,
              ),
        ),
        const SizedBox(height: 32),
        TextField(
          controller: serverController,
          enabled: enabled,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'https://echo.example.com',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: apiKeyController,
          enabled: enabled,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'API Key'),
        ),
        const SizedBox(height: 12),
        Text(
          'The API key stays in secure device storage and is never saved in onboarding progress.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}