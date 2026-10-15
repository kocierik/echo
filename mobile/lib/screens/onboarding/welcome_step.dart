import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

final class WelcomeStep extends StatelessWidget {
  const WelcomeStep({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.hearing_outlined, size: 32, color: palette.accent),
        const SizedBox(height: 24),
        Text('You control listening', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        Text(
          'Echo is ready, but listening is always visible and reversible.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: palette.text2,
              ),
        ),
        const SizedBox(height: 32),
        const _PrivacyRow(
          icon: Icons.radio_button_checked_rounded,
          title: 'Listening',
          detail: 'The app shows when the wearable is actively listening.',
        ),
        Divider(height: 25, color: palette.border),
        const _PrivacyRow(
          icon: Icons.pause_circle_outline_rounded,
          title: 'App mute',
          detail: 'Pause listening from Echo whenever you need privacy.',
        ),
        Divider(height: 25, color: palette.border),
        const _PrivacyRow(
          icon: Icons.watch_outlined,
          title: 'Wearable mute',
          detail: 'The hardware mute control remains available independently.',
        ),
        const SizedBox(height: 24),
        Text(
          'You can review connection and privacy state from the Today screen.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

final class _PrivacyRow extends StatelessWidget {
  const _PrivacyRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: palette.accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(detail, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}