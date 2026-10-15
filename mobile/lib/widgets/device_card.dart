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
    this.batteryPercent,
    this.pendingBytes = 0,
    super.key,
  });

  final PrivacyControlPresentation presentation;

  /// The wearable's battery, when it measures one (null: unknown or not connected).
  final int? batteryPercent;

  /// Speech the wearable holds that has not reached the phone yet (ADPCM bytes).
  final int pendingBytes;
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
            label: [
              visual.title,
              visual.detail,
              if (batteryPercent != null) 'Battery $batteryPercent percent',
              if (pendingSpeechLabel(pendingBytes) case final pending?) pending,
            ].join('. '),
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
                      if (pendingSpeechLabel(pendingBytes) case final pending?)
                        Text(
                          pending,
                          key: const Key('device-pending-speech'),
                          style: textTheme.bodySmall?.copyWith(color: palette.blue),
                        ),
                    ],
                  ),
                ),
                if (batteryPercent != null)
                  BatteryIndicator(percent: batteryPercent!),
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

/// A battery icon and percentage; red when low.
final class BatteryIndicator extends StatelessWidget {
  const BatteryIndicator({required this.percent, super.key});

  final int percent;

  static const lowPercent = 15;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final color = percent < lowPercent ? palette.red : palette.text2;
    return Padding(
      key: const Key('device-battery'),
      padding: const EdgeInsets.only(left: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(batteryIcon(percent), size: 18, color: color),
          const SizedBox(width: 2),
          Text(
            '$percent%',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

IconData batteryIcon(int percent) => switch (percent) {
      >= 90 => Icons.battery_full_rounded,
      >= 60 => Icons.battery_5_bar_rounded,
      >= 35 => Icons.battery_3_bar_rounded,
      >= BatteryIndicator.lowPercent => Icons.battery_2_bar_rounded,
      _ => Icons.battery_alert_rounded,
    };

/// ADPCM at 16 kHz: 8 KB a second.
const _adpcmBytesPerSecond = 8 * 1024;

/// "2 min of speech to sync" (null under 10 s: it is about to arrive anyway).
String? pendingSpeechLabel(int bytes) {
  final seconds = bytes ~/ _adpcmBytesPerSecond;
  if (seconds < 10) return null;
  if (seconds < 60) return '$seconds s of speech to sync';
  return '${(seconds / 60).round()} min of speech to sync';
}
