import 'package:flutter/material.dart';

import '../models/device_status.dart';
import '../theme/app_theme.dart';
import 'device_readings.dart';

/// The wearable at the top of Settings, drawn like the device itself: its LED,
/// battery, speech waiting to sync, and the one action its state calls for
/// (mute, resume, reconnect or pair) next to its details.
final class DeviceInstrumentPanel extends StatelessWidget {
  const DeviceInstrumentPanel({
    required this.status,
    required this.onDetails,
    this.onMute,
    this.onReconnect,
    this.onPair,
    this.busy = false,
    this.firmwareLine,
    super.key,
  });

  final DeviceStatus status;
  final VoidCallback onDetails;

  /// True to mute, false to listen again.
  final ValueChanged<bool>? onMute;
  final VoidCallback? onReconnect;
  final VoidCallback? onPair;
  final bool busy;

  /// "Firmware 0.5.0", or that a new one is ready.
  final String? firmwareLine;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final state = status.connectionState;
    final battery = status.batteryPercent;
    final waiting = pendingSpeechLabel(status.bufferBytes);
    final (label, led) = switch (state) {
      DeviceConnectionState.listening => ('Listening', palette.live),
      DeviceConnectionState.muted => ('Muted', null),
      DeviceConnectionState.scanning ||
      DeviceConnectionState.connecting ||
      DeviceConnectionState.bonding ||
      DeviceConnectionState.reconnecting =>
        ('Connecting', palette.amber),
      DeviceConnectionState.bluetoothOff => ('Bluetooth is off', palette.red),
      DeviceConnectionState.offline || DeviceConnectionState.error => ('Offline', palette.red),
      DeviceConnectionState.unpaired => ('No Echo paired', null),
    };
    final action = switch (state) {
      DeviceConnectionState.listening when onMute != null =>
        ('Mute Echo', () => onMute!(true)),
      DeviceConnectionState.muted when onMute != null =>
        ('Listen again', () => onMute!(false)),
      DeviceConnectionState.offline || DeviceConnectionState.error when onReconnect != null =>
        ('Reconnect', onReconnect!),
      DeviceConnectionState.unpaired when onPair != null => ('Pair Echo', onPair!),
      _ => null,
    };

    return Container(
      key: const Key('device-instrument'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _Device(led: led, glow: state == DeviceConnectionState.listening),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(label, style: textTheme.titleLarge?.copyWith(fontSize: 18)),
                    ),
                    if (battery != null) ...[
                      const SizedBox(height: 9),
                      _Reading(name: 'Battery', value: '$battery%'),
                      const SizedBox(height: 5),
                      _BatteryBar(percent: battery),
                    ],
                    if (waiting != null) ...[
                      const SizedBox(height: 8),
                      Text(waiting, style: textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (action != null) ...[
                Expanded(
                  child: FilledButton(
                    key: const Key('device-instrument-action'),
                    onPressed: busy ? null : action.$2,
                    child: Text(action.$1, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: FilledButton(
                  key: const Key('device-details'),
                  onPressed: onDetails,
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.background,
                    foregroundColor: palette.text,
                  ),
                  child: const Text('Device details', maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ),
          if (firmwareLine != null) ...[
            const SizedBox(height: 14),
            Text(firmwareLine!, style: textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// The round wearable with its LED near the top: lit and glowing while it
/// listens, a ring when it is muted or away.
final class _Device extends StatelessWidget {
  const _Device({required this.led, required this.glow});

  final Color? led;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return ExcludeSemantics(
      child: Container(
        width: 88,
        height: 88,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: palette.chromeRaised, shape: BoxShape.circle),
        child: Container(
          width: 66,
          height: 66,
          alignment: Alignment.topCenter,
          padding: const EdgeInsets.only(top: 10),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: palette.chromeLine, width: 2),
          ),
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: led,
              border: led == null ? Border.all(color: palette.onChromeMuted, width: 1.5) : null,
              boxShadow: glow ? [BoxShadow(color: palette.liveGlow, spreadRadius: 5)] : null,
            ),
          ),
        ),
      ),
    );
  }
}

final class _Reading extends StatelessWidget {
  const _Reading({required this.name, required this.value});

  final String name;
  final String value;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12);
    return Row(
      children: [
        Expanded(child: Text(name, style: style)),
        Text(value, style: style),
      ],
    );
  }
}

/// Ten segments, filled as far as the battery goes; red when it is low.
final class _BatteryBar extends StatelessWidget {
  const _BatteryBar({required this.percent});

  final int percent;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final filled = (percent / 10).ceil().clamp(0, 10);
    final low = percent < lowBatteryPercent;
    return ExcludeSemantics(
      child: Row(
        children: [
          for (var i = 0; i < 10; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: Container(
                height: 7,
                decoration: BoxDecoration(
                  color: i < filled ? (low ? palette.red : palette.text) : palette.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
