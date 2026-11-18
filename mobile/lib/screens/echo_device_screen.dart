import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device_status.dart';
import '../services/app/app_controller.dart';
import '../services/app/app_runtime.dart';
import '../services/onboarding/onboarding_controller.dart';
import '../services/device/device_controller.dart';
import '../services/device/device_protocol.dart';
import '../services/device/firmware_update.dart';
import '../widgets/device_instrument.dart';
import '../widgets/device_readings.dart' show microSdLabel;
import '../widgets/firmware_update_section.dart';
import 'settings/settings_components.dart';
import 'navigation.dart';

/// Pushes the Echo screen; the app's own device and preferences unless given (tests).
Future<void> openEchoDevice(
  BuildContext context, {
  required AppController appController,
  DeviceController? deviceController,
  SharedPreferences? preferences,
  VoidCallback? onRequireOnboarding,
}) async {
  final coordinator = AppRuntime.maybeCoordinator;
  final device = deviceController ?? coordinator?.deviceController;
  final prefs = preferences ?? coordinator?.preferences;
  if (device == null || prefs == null) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => EchoDeviceScreen(
      appController: appController,
      deviceController: device,
      resetOnboarding: () => clearOnboardingProgress(prefs),
      onRequireOnboarding: onRequireOnboarding,
      firmwareUpdate: coordinator?.firmwareUpdate,
    ),
  ));
}

/// Forgetting Echo starts the setup over at pairing.
Future<void> clearOnboardingProgress(SharedPreferences preferences) async {
  final removed = await Future.wait([
    preferences.remove(OnboardingController.completedKey),
    preferences.remove(OnboardingController.highestStepKey),
    preferences.remove('echo_onboarding_complete'),
  ]);
  if (removed.any((success) => !success)) {
    throw StateError('Could not clear onboarding progress');
  }
}

/// The "Echo" screen: the wearable drawn as the instrument (its state, battery, mute),
/// then its readings, the firmware update, reconnecting, pairing and forgetting it.
/// Opened from the device pill on Today and Ask and from the Profile device card.
class EchoDeviceScreen extends StatefulWidget {
  const EchoDeviceScreen({
    required this.appController,
    required this.deviceController,
    required this.resetOnboarding,
    this.onForgot,
    this.onRequireOnboarding,
    this.firmwareUpdate,
    super.key,
  });

  final AppController appController;
  final DeviceController deviceController;
  final Future<void> Function() resetOnboarding;
  final VoidCallback? onForgot;
  final VoidCallback? onRequireOnboarding;

  /// Null in tests that do not exercise updates.
  final FirmwareUpdateController? firmwareUpdate;

  @override
  State<EchoDeviceScreen> createState() => _EchoDeviceScreenState();
}

class _EchoDeviceScreenState extends State<EchoDeviceScreen> {
  bool _reconnecting = false;
  bool _forgetting = false;
  bool _muteBusy = false;
  bool _turningOff = false;
  String? _error;

  /// The microphone's gain last set from this phone (Echo does not report it).
  int _micGain = DeviceProtocol.defaultMicGain;
  static const _micGainKey = 'echo_mic_gain';

  @override
  void initState() {
    super.initState();
    unawaited(_loadMicGain());
  }

  Future<void> _loadMicGain() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getInt(_micGainKey);
      if (saved != null && mounted) setState(() => _micGain = saved);
    } catch (_) {
      // No saved gain: the default, as on Echo
    }
  }

  /// Louder or quieter: Echo applies it at once and keeps it across restarts.
  Future<void> _setMicGain(int gain) async {
    try {
      await widget.deviceController.setMicGain(gain);
    } catch (_) {
      if (mounted) setState(() => _error = 'Echo could not update the microphone.');
      return;
    }
    try {
      await (await SharedPreferences.getInstance()).setInt(_micGainKey, gain);
    } catch (_) {
      // Not remembered on this phone: Echo still has it
    }
  }

  /// Mute Echo or let it listen again; the instrument changes once Echo confirms.
  Future<void> _setMuted(bool muted) async {
    setState(() => _muteBusy = true);
    try {
      await widget.deviceController.setMuted(muted);
    } catch (_) {
      if (mounted) setState(() => _error = 'Echo could not update the microphone.');
    } finally {
      if (mounted) setState(() => _muteBusy = false);
    }
  }

  /// Echo finishes syncing, then turns off; the instrument follows what Echo reports.
  Future<void> _turnOff() async {
    if (_turningOff) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Turn off Echo?'),
            content: const Text(
              'Echo will finish syncing, then turn off. '
              'Hold its button for 2 seconds to turn it on again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Turn off'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || _turningOff || !mounted) return;
    setState(() {
      _turningOff = true;
      _error = null;
    });
    try {
      await widget.deviceController.turnOff();
    } on StateError catch (error) {
      // Echo refused (it is updating); any other StateError is a failure like the rest
      final refused = error.message == DeviceController.refusedUpdatingMessage;
      if (mounted) {
        setState(() => _error = refused
            ? error.message
            : 'Echo could not be turned off. Keep it nearby and try again.');
      }
    } catch (_) {
      // No answer in time (TimeoutException), or the link failed
      if (mounted) {
        setState(() => _error = 'Echo could not be turned off. Keep it nearby and try again.');
      }
    } finally {
      if (mounted) setState(() => _turningOff = false);
    }
  }

  Future<void> _keepOn() async {
    try {
      await widget.deviceController.cancelTurnOff();
    } catch (_) {
      if (mounted) setState(() => _error = 'Echo could not be kept on. Try again.');
    }
  }

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
      popToTabs(context);
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
    popToTabs(context);
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
          DeviceConnectionState.error =>
            true,
          _ => false,
        };
        return SettingsPageScaffold(
          title: 'Echo',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              // Its state and battery; reconnecting and pairing have their rows below
              child: DeviceInstrumentPanel(
                status: status,
                busy: _muteBusy,
                onMute: (muted) => _setMuted(muted),
                onKeepOn: _keepOn,
              ),
            ),
            const SettingsSection('STATUS'),
            if (status.batteryPercent == null)
              const SettingsRow(
                icon: Icons.battery_unknown_outlined,
                title: 'Battery',
                value: 'Not measured',
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
            if (widget.firmwareUpdate != null)
              FirmwareUpdateSection(controller: widget.firmwareUpdate!),
            if (status.firmwareVersion != null &&
                !isNewerFirmware(DeviceProtocol.micGainFirmware, status.firmwareVersion)) ...[
              const SettingsSection('MICROPHONE'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    const Icon(Icons.mic_none_rounded),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Slider(
                        key: const Key('device-mic-gain'),
                        value: _micGain.toDouble(),
                        min: 1,
                        max: DeviceProtocol.maxMicGain.toDouble(),
                        divisions: DeviceProtocol.maxMicGain - 1,
                        label: '×$_micGain',
                        semanticFormatterCallback: (value) => 'Microphone gain ${value.round()}',
                        onChanged: (value) => setState(() => _micGain = value.round()),
                        onChangeEnd: (value) => unawaited(_setMicGain(value.round())),
                      ),
                    ),
                    Text('×$_micGain'),
                  ],
                ),
              ),
            ],
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
            if (status.microSd != null)
              SettingsRow(
                key: const Key('device-microsd'),
                icon: Icons.sd_card_outlined,
                title: 'microSD',
                subtitle: microSdLabel(status.microSd!),
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
            if (status.firmwareVersion != null &&
                !isNewerFirmware(DeviceProtocol.powerOffFirmware, status.firmwareVersion) &&
                (status.connectionState == DeviceConnectionState.listening ||
                    status.connectionState == DeviceConnectionState.muted))
              SettingsRow(
                key: const Key('device-turn-off'),
                icon: Icons.power_settings_new_rounded,
                title: _turningOff ? 'Turning off...' : 'Turn off Echo',
                onTap: _turningOff ? null : _turnOff,
              ),
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
}
