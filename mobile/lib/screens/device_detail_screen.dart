import 'package:flutter/material.dart';

import '../models/device_status.dart';
import '../services/app/app_controller.dart';
import '../services/device/device_controller.dart';
import '../widgets/device_card.dart';
import 'settings/settings_components.dart';

class DeviceDetailScreen extends StatefulWidget {
  const DeviceDetailScreen({
    required this.appController,
    required this.deviceController,
    required this.resetOnboarding,
    this.onForgot,
    this.onRequireOnboarding,
    super.key,
  });

  final AppController appController;
  final DeviceController deviceController;
  final Future<void> Function() resetOnboarding;
  final VoidCallback? onForgot;
  final VoidCallback? onRequireOnboarding;

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  bool _reconnecting = false;
  bool _forgetting = false;
  String? _error;

  Future<void> _reconnect() async {
    if (_reconnecting) return;
    setState(() {
      _reconnecting = true;
      _error = null;
    });
    try {
      await widget.deviceController.reconnect();
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Echo could not start reconnecting. Try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _reconnecting = false);
    }
  }

  Future<void> _forget() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Forget this Echo?'),
            content: const Text(
              'Echo will disconnect and must be paired again before recording can resume.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Forget device'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || _forgetting) return;

    setState(() {
      _forgetting = true;
      _error = null;
    });
    try {
      await widget.deviceController.forget();
      await widget.resetOnboarding();
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      widget.onForgot?.call();
      widget.onRequireOnboarding?.call();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _forgetting = false;
        _error = 'Echo could not be forgotten. Keep it nearby and try again.';
      });
    }
  }

  /// Reopens the onboarding at its pairing step, over the whole app.
  void _pair() {
    Navigator.of(context).popUntil((route) => route.isFirst);
    widget.onRequireOnboarding?.call();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: widget.appController,
      builder: (context, appState, child) {
        final status = appState.device;
        final reconnectAvailable = switch (status.connectionState) {
          DeviceConnectionState.bluetoothOff ||
          DeviceConnectionState.offline ||
          DeviceConnectionState.error => true,
          _ => false,
        };
        return SettingsPageScaffold(
          title: 'Device',
          children: [
            const SettingsSection('STATUS'),
            SettingsRow(
              icon: _stateIcon(status.connectionState),
              title: 'Connection',
              value: _stateLabel(status.connectionState),
            ),
            SettingsRow(
              icon: status.batteryPercent == null
                  ? Icons.battery_unknown_outlined
                  : batteryIcon(status.batteryPercent!),
              title: 'Battery',
              value: status.batteryPercent == null
                  ? 'Not measured'
                  : '${status.batteryPercent}%',
            ),
            if (status.protocolVersion != null)
              SettingsRow(
                icon: Icons.hub_outlined,
                title: 'Protocol',
                value: status.protocolVersion.toString(),
              ),
            if (status.firmwareVersion != null)
              SettingsRow(
                icon: Icons.memory_outlined,
                title: 'Firmware',
                value: status.firmwareVersion,
              ),
            const SettingsSection('BUFFER'),
            SettingsRow(
              icon: Icons.inventory_2_outlined,
              title: 'Buffered segments',
              value: status.bufferCount.toString(),
            ),
            SettingsRow(
              icon: Icons.data_usage_outlined,
              title: 'Buffered bytes',
              value: status.bufferBytes.toString(),
            ),
            SettingsRow(
              icon: Icons.warning_amber_rounded,
              title: 'Dropped segments',
              value: status.droppedSegments.toString(),
            ),
            if (reconnectAvailable) ...[
              const SettingsSection('CONNECTION'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('device-reconnect'),
                    onPressed: _reconnecting ? null : _reconnect,
                    icon: _reconnecting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync_rounded),
                    label: Text(
                      _reconnecting ? 'Starting reconnect...' : 'Reconnect',
                    ),
                  ),
                ),
              ),
            ],
            if (status.connectionState == DeviceConnectionState.unpaired &&
                widget.onRequireOnboarding != null) ...[
              const SettingsSection('PAIRING'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('device-pair'),
                    onPressed: _pair,
                    icon: const Icon(Icons.bluetooth_searching_rounded),
                    label: const Text('Pair Echo'),
                  ),
                ),
              ),
            ],
            const SettingsSection('DEVICE'),
            SettingsRow(
              icon: Icons.link_off_rounded,
              title: _forgetting ? 'Forgetting device...' : 'Forget device',
              destructive: true,
              onTap: _forgetting ? null : _forget,
              trailing: _forgetting
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
            ),
            if (_error != null)
              SettingsMessage(
                _error!,
                error: true,
                key: const Key('device-action-error'),
              ),
            if (status.error != null && status.error != _error)
              SettingsMessage(status.error!, error: true),
          ],
        );
      },
    );
  }

  static String _stateLabel(DeviceConnectionState state) {
    return switch (state) {
      DeviceConnectionState.unpaired => 'Not paired',
      DeviceConnectionState.bluetoothOff => 'Bluetooth unavailable',
      DeviceConnectionState.scanning => 'Scanning',
      DeviceConnectionState.connecting => 'Connecting',
      DeviceConnectionState.bonding => 'Pairing',
      DeviceConnectionState.listening => 'Listening',
      DeviceConnectionState.muted => 'Muted',
      DeviceConnectionState.reconnecting => 'Reconnecting',
      DeviceConnectionState.offline => 'Offline',
      DeviceConnectionState.error => 'Error',
    };
  }

  static IconData _stateIcon(DeviceConnectionState state) {
    return switch (state) {
      DeviceConnectionState.listening => Icons.hearing_rounded,
      DeviceConnectionState.muted => Icons.mic_off_outlined,
      DeviceConnectionState.offline ||
      DeviceConnectionState.error ||
      DeviceConnectionState.bluetoothOff => Icons.bluetooth_disabled_rounded,
      _ => Icons.bluetooth_searching_rounded,
    };
  }
}