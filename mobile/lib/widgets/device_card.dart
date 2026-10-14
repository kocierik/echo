import 'package:flutter/material.dart';

import '../models/device_status.dart';
import '../theme/app_theme.dart';
import 'privacy_control.dart';

/// What Today shows about the wearable: one card with its state and the one
/// action that matters now (mute, resume, reconnect or pair).
final class DeviceCard extends StatelessWidget {
  const DeviceCard({
    required this.presentation,
    this.onAction,
    this.busy = false,
    this.error,
    this.announcement,
    super.key,
  });

  final PrivacyControlPresentation presentation;
  final VoidCallback? onAction;
  final bool busy;
  final String? error;
  final String? announcement;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final visual = deviceVisual(presentation, palette);
    return Container(
      key: const Key('device-card'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            label: '${visual.title}. ${visual.detail}',
            excludeSemantics: true,
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: visual.color.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(visual.icon, size: 22, color: visual.color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(visual.title, style: textTheme.titleMedium),
                      Text(
                        visual.detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          PrivacyControl(
            presentation: presentation,
            onPressed: onAction,
            busy: busy,
            error: error,
            onRetry: onAction,
            announcement: announcement,
          ),
        ],
      ),
    );
  }
}

/// Which card a connection state shows.
PrivacyControlPresentation devicePresentation(DeviceConnectionState state) {
  return switch (state) {
    DeviceConnectionState.listening => PrivacyControlPresentation.listening,
    DeviceConnectionState.muted => PrivacyControlPresentation.muted,
    DeviceConnectionState.scanning ||
    DeviceConnectionState.connecting ||
    DeviceConnectionState.bonding ||
    DeviceConnectionState.reconnecting => PrivacyControlPresentation.connecting,
    DeviceConnectionState.unpaired => PrivacyControlPresentation.unpaired,
    DeviceConnectionState.bluetoothOff ||
    DeviceConnectionState.offline ||
    DeviceConnectionState.error => PrivacyControlPresentation.offline,
  };
}

@immutable
final class DeviceVisual {
  const DeviceVisual({
    required this.title,
    required this.detail,
    required this.icon,
    required this.color,
  });

  final String title;
  final String detail;
  final IconData icon;
  final Color color;
}

DeviceVisual deviceVisual(PrivacyControlPresentation presentation, EchoPalette palette) {
  return switch (presentation) {
    PrivacyControlPresentation.listening => DeviceVisual(
        title: 'Listening',
        detail: 'Echo captures conversations. Mute it any time.',
        icon: Icons.graphic_eq_rounded,
        color: palette.green,
      ),
    PrivacyControlPresentation.muted => DeviceVisual(
        title: 'Microphone muted',
        detail: 'Echo is not listening. Resume whenever you are ready.',
        icon: Icons.mic_off_rounded,
        color: palette.red,
      ),
    PrivacyControlPresentation.connecting => DeviceVisual(
        title: 'Connecting',
        detail: 'Echo is restoring the private device connection.',
        icon: Icons.bluetooth_searching_rounded,
        color: palette.amber,
      ),
    PrivacyControlPresentation.offline => DeviceVisual(
        title: 'Echo is offline',
        detail: 'Reconnect when the device is nearby and Bluetooth is on.',
        icon: Icons.bluetooth_disabled_rounded,
        color: palette.blue,
      ),
    PrivacyControlPresentation.unpaired => DeviceVisual(
        title: 'No Echo paired',
        detail: 'Pair your Echo to start capturing conversations.',
        icon: Icons.bluetooth_rounded,
        color: palette.blue,
      ),
  };
}
