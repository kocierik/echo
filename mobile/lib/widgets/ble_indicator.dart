import 'package:flutter/material.dart';
import '../services/ble_service.dart';
import '../theme/app_theme.dart';

class BleIndicator extends StatelessWidget {
  final BleConnectionState state;
  final VoidCallback onTap;

  const BleIndicator({super.key, required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 14, color: _color),
            const SizedBox(width: 5),
            Text(_label, style: TextStyle(fontSize: 11, color: _color)),
          ],
        ),
      ),
    );
  }

  Color get _color {
    switch (state) {
      case BleConnectionState.connected: return AppColors.success;
      case BleConnectionState.scanning:
      case BleConnectionState.connecting: return AppColors.accent;
      case BleConnectionState.disconnected: return AppColors.foregroundMuted;
    }
  }

  Color get _borderColor {
    switch (state) {
      case BleConnectionState.connected: return AppColors.success.withOpacity(0.3);
      case BleConnectionState.scanning:
      case BleConnectionState.connecting: return AppColors.accent.withOpacity(0.3);
      case BleConnectionState.disconnected: return AppColors.border;
    }
  }

  IconData get _icon {
    switch (state) {
      case BleConnectionState.connected: return Icons.bluetooth_connected_rounded;
      case BleConnectionState.scanning: return Icons.bluetooth_searching_rounded;
      case BleConnectionState.connecting: return Icons.bluetooth_rounded;
      case BleConnectionState.disconnected: return Icons.bluetooth_disabled_rounded;
    }
  }

  String get _label {
    switch (state) {
      case BleConnectionState.connected: return 'Device';
      case BleConnectionState.scanning: return 'Scanning...';
      case BleConnectionState.connecting: return 'Connecting...';
      case BleConnectionState.disconnected: return 'No device';
    }
  }
}
