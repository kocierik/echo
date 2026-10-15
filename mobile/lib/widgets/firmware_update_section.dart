import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/settings/settings_components.dart';
import '../services/device/firmware_update.dart';

/// Settings → Device: a newer firmware, the update in progress, or how it ended.
class FirmwareUpdateSection extends StatelessWidget {
  const FirmwareUpdateSection({required this.controller, super.key});

  final FirmwareUpdateController controller;

  Future<void> _confirmAndInstall(
      BuildContext context, FirmwareRelease release) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Update Echo to ${release.version}?'),
            content: const Text(
              'Echo first sends what it still holds, then its microphone pauses for about a '
              'minute while the update arrives. Keep the app open and Echo nearby.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('firmware-confirm'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Update'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed) unawaited(controller.install());
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FirmwareUpdateState>(
      valueListenable: controller,
      builder: (context, update, _) {
        final release = update.release;
        if (update.phase == FirmwareUpdatePhase.idle || release == null) {
          return const SizedBox.shrink();
        }
        final notes = release.notes;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsSection('UPDATE'),
            ...switch (update.phase) {
              FirmwareUpdatePhase.available => [
                  SettingsRow(
                    icon: Icons.system_update_alt_rounded,
                    title: 'Firmware ${release.version} is ready',
                    subtitle: notes,
                  ),
                  _Button(
                    key: const Key('firmware-update'),
                    label: 'Update Echo',
                    icon: Icons.download_rounded,
                    onPressed: () =>
                        unawaited(_confirmAndInstall(context, release)),
                  ),
                ],
              FirmwareUpdatePhase.needsCable => [
                  SettingsMessage(
                    'Firmware ${release.version} is published. Echo\'s current firmware '
                    'predates updates over Bluetooth: install this one with the USB cable, '
                    'and the next ones arrive here.',
                    key: const Key('firmware-needs-cable'),
                  ),
                ],
              FirmwareUpdatePhase.syncing ||
              FirmwareUpdatePhase.downloading ||
              FirmwareUpdatePhase.sending ||
              FirmwareUpdatePhase.restarting =>
                [_Progress(update: update, onCancel: controller.cancel)],
              FirmwareUpdatePhase.done => [
                  SettingsMessage(update.message ?? 'Echo is up to date.',
                      key: const Key('firmware-done')),
                ],
              FirmwareUpdatePhase.failed => [
                  SettingsMessage(
                    update.message ?? 'The update did not go through.',
                    error: true,
                    key: const Key('firmware-failed'),
                  ),
                  _Button(
                    key: const Key('firmware-retry'),
                    label: 'Try again',
                    icon: Icons.refresh_rounded,
                    onPressed: controller.reset,
                  ),
                ],
              FirmwareUpdatePhase.idle => const <Widget>[],
            },
          ],
        );
      },
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.update, required this.onCancel});

  final FirmwareUpdateState update;
  final Future<void> Function() onCancel;

  @override
  Widget build(BuildContext context) {
    final sending = update.phase == FirmwareUpdatePhase.sending;
    final label = switch (update.phase) {
      FirmwareUpdatePhase.syncing => 'Sending what Echo still holds…',
      FirmwareUpdatePhase.downloading =>
        'Downloading ${update.release?.version}…',
      FirmwareUpdatePhase.sending =>
        'Installing on Echo… ${(update.progress * 100).round()}%',
      _ => 'Echo is restarting…',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, key: const Key('firmware-progress-label')),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: sending ? update.progress : null),
          const SizedBox(height: 8),
          Text(
            'Keep the app open and Echo nearby.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (update.phase != FirmwareUpdatePhase.restarting)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('firmware-cancel'),
                onPressed: () => unawaited(onCancel()),
                child: const Text('Cancel'),
              ),
            ),
        ],
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({
    required this.label,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
            onPressed: onPressed, icon: Icon(icon), label: Text(label)),
      ),
    );
  }
}
