import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/panel.dart';

final class PermissionsStep extends StatelessWidget {
  const PermissionsStep({
    required this.backgroundExplanation,
    required this.notificationDenied,
    required this.voiceDenied,
    super.key,
  });

  final String backgroundExplanation;
  final bool notificationDenied;
  final bool voiceDenied;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.shield_outlined, size: 32, color: palette.accent),
        const SizedBox(height: 24),
        Text('Permissions', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        Text(
          'Choose what Echo can use. Bluetooth is required; alerts and voice Ask can stay off.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: palette.text2,
              ),
        ),
        const SizedBox(height: 28),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            const _PermissionRow(
              icon: Icons.bluetooth_rounded,
              title: 'Bluetooth',
              detail: 'Required to find and stay connected to your wearable.',
              required: true,
            ),
            Divider(height: 25, color: palette.border),
            _PermissionRow(
              icon: Icons.notifications_none_rounded,
              title: 'Notifications',
              detail: notificationDenied
                  ? 'Off. Echo will continue without disconnect alerts.'
                  : 'Optional alerts for disconnects and upload problems.',
            ),
            Divider(height: 25, color: palette.border),
            _PermissionRow(
              icon: Icons.mic_none_rounded,
              title: 'Microphone',
              detail: voiceDenied
                  ? 'Off. Typed Ask remains available.'
                  : 'Optional, used only when you start voice Ask.',
            ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, size: 18, color: palette.text2),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                backgroundExplanation,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

final class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.icon,
    required this.title,
    required this.detail,
    this.required = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool required;

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
              Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (required) ...[
                    const SizedBox(width: 8),
                    Text(
                      'REQUIRED',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: palette.accent,
                            fontSize: 11,
                          ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(detail, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}