import 'package:flutter/material.dart';

import '../models/device_status.dart';
import '../theme/app_theme.dart';

/// The wearable in the top right of every tab: its LED and battery (or what is
/// wrong). A tap opens Settings; a long press mutes it, or resumes listening.
final class DevicePill extends StatelessWidget {
  const DevicePill({
    required this.status,
    this.onTap,
    this.onLongPress,
    super.key,
  });

  final DeviceStatus status;
  final VoidCallback? onTap;

  /// Mute or resume; only offered while listening or muted.
  final VoidCallback? onLongPress;

  bool get _canMute =>
      status.connectionState == DeviceConnectionState.listening ||
      status.connectionState == DeviceConnectionState.muted;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final look = _look(palette);
    return Semantics(
      key: const Key('device-pill'),
      button: true,
      liveRegion: true,
      label: look.spoken,
      hint: _canMute && onLongPress != null
          ? (status.connectionState == DeviceConnectionState.muted
              ? 'Opens settings. Long press to resume listening'
              : 'Opens settings. Long press to mute')
          : 'Opens settings',
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: _canMute ? onLongPress : null,
      child: Material(
        color: palette.chrome,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          onLongPress: _canMute ? onLongPress : null,
          child: Container(
            height: 44,
            padding: const EdgeInsets.only(left: 12, right: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (look.dot != null) ...[
                  _Led(color: look.dot!, glow: look.glow, hollow: look.hollow),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    look.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: palette.onChrome,
                      fontSize: 14,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  _PillLook _look(EchoPalette palette) {
    final battery = status.batteryPercent;
    final batteryText = battery == null ? null : '$battery%';
    final spokenBattery = battery == null ? '' : ', battery $battery%';
    return switch (status.connectionState) {
      DeviceConnectionState.listening => _PillLook(
          label: batteryText ?? 'On',
          spoken: 'Echo is listening$spokenBattery',
          dot: palette.live,
          glow: palette.liveGlow,
        ),
      DeviceConnectionState.muted => _PillLook(
          label: 'Muted',
          spoken: 'Echo is muted$spokenBattery',
          dot: palette.onChromeMuted,
          hollow: true,
        ),
      DeviceConnectionState.turningOff => _PillLook(
          label: 'Turning off',
          spoken: 'Echo is turning off',
          dot: palette.amber),
      DeviceConnectionState.off => _PillLook(
          label: 'Off',
          spoken: 'Echo is off',
          dot: palette.onChromeMuted,
          hollow: true,
        ),
      DeviceConnectionState.scanning ||
      DeviceConnectionState.connecting ||
      DeviceConnectionState.bonding ||
      DeviceConnectionState.reconnecting =>
        _PillLook(
            label: 'Connecting',
            spoken: 'Echo is connecting',
            dot: palette.amber),
      DeviceConnectionState.bluetoothOff => _PillLook(
          label: 'Bluetooth off', spoken: 'Bluetooth is off', dot: palette.red),
      DeviceConnectionState.offline || DeviceConnectionState.error => _PillLook(
          label: 'Offline', spoken: 'Echo is offline', dot: palette.red),
      DeviceConnectionState.unpaired =>
        const _PillLook(label: 'Set up Echo', spoken: 'No Echo paired'),
    };
  }
}

final class _PillLook {
  const _PillLook({
    required this.label,
    required this.spoken,
    this.dot,
    this.glow,
    this.hollow = false,
  });

  final String label;
  final String spoken;
  final Color? dot;
  final Color? glow;
  final bool hollow;
}

/// The wearable's LED: lit (with its glow), or a ring when muted.
final class _Led extends StatelessWidget {
  const _Led({required this.color, this.glow, this.hollow = false});

  final Color color;
  final Color? glow;
  final bool hollow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: hollow ? null : color,
        border: hollow ? Border.all(color: color, width: 1.5) : null,
        boxShadow:
            glow == null ? null : [BoxShadow(color: glow!, spreadRadius: 3)],
      ),
    );
  }
}
