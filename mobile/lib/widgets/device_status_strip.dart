import 'package:flutter/material.dart';

import '../models/device_status.dart';
import '../theme/app_theme.dart';

final class DeviceStatusStrip extends StatelessWidget {
  const DeviceStatusStrip({
    required this.status,
    this.onTap,
    super.key,
  });

  final DeviceStatus status;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final presentation = _presentation(palette);
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 32,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: presentation.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                presentation.icon,
                size: 20,
                color: presentation.color,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              presentation.copy,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: presentation.color,
                  ),
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: palette.text2,
            ),
          ],
        ],
      ),
    );

    return Semantics(
      key: const Key('device-status-semantics'),
      label: 'Device status: ${presentation.copy}',
      liveRegion: true,
      button: onTap != null,
      onTap: onTap,
      excludeSemantics: true,
      child: SizedBox(
        height: 56,
        child: onTap == null
            ? content
            : Material(
                color: Colors.transparent,
                child: InkWell(
                  key: const Key('device-status-action'),
                  onTap: onTap,
                  child: content,
                ),
              ),
      ),
    );
  }

  _StatusPresentation _presentation(EchoPalette palette) {
    return switch (status.connectionState) {
      DeviceConnectionState.unpaired => _StatusPresentation(
          copy: 'Set up wearable',
          color: palette.blue,
          icon: Icons.watch_outlined,
        ),
      DeviceConnectionState.bluetoothOff => _StatusPresentation(
          copy: 'Bluetooth is off',
          color: palette.amber,
          icon: Icons.bluetooth_disabled_rounded,
        ),
      DeviceConnectionState.scanning => _StatusPresentation(
          copy: 'Finding Echo',
          color: palette.blue,
          icon: Icons.bluetooth_searching_rounded,
        ),
      DeviceConnectionState.connecting => _StatusPresentation(
          copy: 'Connecting',
          color: palette.blue,
          icon: Icons.sync_rounded,
        ),
      DeviceConnectionState.bonding => _StatusPresentation(
          copy: 'Securing connection',
          color: palette.blue,
          icon: Icons.lock_outline_rounded,
        ),
      DeviceConnectionState.listening => _StatusPresentation(
          copy: 'Listening',
          color: palette.green,
          icon: Icons.hearing_rounded,
        ),
      DeviceConnectionState.muted => _StatusPresentation(
          copy: 'Muted',
          color: palette.red,
          icon: Icons.privacy_tip_outlined,
        ),
      DeviceConnectionState.reconnecting => _StatusPresentation(
          copy: 'Reconnecting',
          color: palette.amber,
          icon: Icons.sync_rounded,
        ),
      DeviceConnectionState.offline => _StatusPresentation(
          copy: 'Echo offline',
          color: palette.red,
          icon: Icons.cloud_off_outlined,
        ),
      DeviceConnectionState.error => _StatusPresentation(
          copy: _errorCopy,
          color: palette.red,
          icon: Icons.error_outline_rounded,
        ),
    };
  }

  String get _errorCopy {
    final error = status.error?.trim();
    return error == null || error.isEmpty ? 'Connection error' : error;
  }
}

final class _StatusPresentation {
  const _StatusPresentation({
    required this.copy,
    required this.color,
    required this.icon,
  });

  final String copy;
  final Color color;
  final IconData icon;
}