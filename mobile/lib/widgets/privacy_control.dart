import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum PrivacyControlPresentation { listening, muted, connecting, offline, unpaired }

final class PrivacyControl extends StatelessWidget {
  const PrivacyControl({
    required this.presentation,
    this.onPressed,
    this.busy = false,
    this.error,
    this.onRetry,
    this.announcement,
    super.key,
  });

  final PrivacyControlPresentation presentation;
  final VoidCallback? onPressed;
  final bool busy;
  final String? error;
  final VoidCallback? onRetry;
  final String? announcement;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final config = _config(palette);
    final enabled = onPressed != null && !busy;
    final errorText = error;

    return Semantics(
      container: true,
      liveRegion: true,
      label: announcement ?? config.label,
      value: busy ? 'Waiting for Echo to confirm' : errorText,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 48,
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('privacy-action'),
              onPressed: enabled ? onPressed : null,
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.disabled)) {
                    return config.background.withValues(alpha: 0.62);
                  }
                  return config.background;
                }),
                foregroundColor: WidgetStatePropertyAll(config.foreground),
                side: WidgetStatePropertyAll(
                  BorderSide(color: config.border),
                ),
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              icon: busy || presentation == PrivacyControlPresentation.connecting
                  ? SizedBox.square(
                      key: const Key('privacy-progress'),
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: config.foreground,
                      ),
                    )
                  : Icon(config.icon, size: 22),
              label: Text(
                config.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (errorText != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    errorText,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.red,
                        ),
                  ),
                ),
                if (onRetry != null)
                  SizedBox(
                    height: 44,
                    child: TextButton(
                      key: const Key('privacy-retry'),
                      onPressed: busy ? null : onRetry,
                      child: const Text('Retry'),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  _PrivacyControlConfig _config(EchoPalette palette) {
    return switch (presentation) {
      PrivacyControlPresentation.listening => _PrivacyControlConfig(
          label: 'Mute microphone',
          icon: Icons.mic_off_outlined,
          background: palette.surface2,
          foreground: palette.text,
          border: palette.border,
        ),
      PrivacyControlPresentation.muted => _PrivacyControlConfig(
          label: 'Resume listening',
          icon: Icons.mic_outlined,
          background: palette.red.withValues(alpha: 0.12),
          foreground: palette.red,
          border: palette.red.withValues(alpha: 0.5),
        ),
      PrivacyControlPresentation.connecting => _PrivacyControlConfig(
          label: 'Connecting…',
          icon: Icons.sync_rounded,
          background: palette.surface2,
          foreground: palette.text2,
          border: palette.border,
        ),
      PrivacyControlPresentation.offline => _PrivacyControlConfig(
          label: 'Reconnect Echo',
          icon: Icons.bluetooth_searching_rounded,
          background: palette.blue,
          foreground: Colors.white,
          border: palette.blue,
        ),
      PrivacyControlPresentation.unpaired => _PrivacyControlConfig(
          label: 'Pair Echo',
          icon: Icons.bluetooth_rounded,
          background: palette.blue,
          foreground: Colors.white,
          border: palette.blue,
        ),
    };
  }
}

final class _PrivacyControlConfig {
  const _PrivacyControlConfig({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.border,
  });

  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;
  final Color border;
}