import 'package:flutter/material.dart';

import '../../models/device_status.dart';
import '../../services/app_controller.dart';
import 'settings_components.dart';

class PrivacySettingsScreen extends StatelessWidget {
  const PrivacySettingsScreen({
    required this.appController,
    this.onOpenTranscripts,
    super.key,
  });

  final AppController appController;
  final VoidCallback? onOpenTranscripts;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: appController,
      builder: (context, state, child) {
        final connectionState = state.device.connectionState;
        final microphoneStatus = switch (connectionState) {
          DeviceConnectionState.muted => 'Muted',
          DeviceConnectionState.listening => 'Listening',
          _ => 'Unavailable',
        };
        return SettingsPageScaffold(
          title: 'Privacy',
          children: [
            const SettingsSection('RETENTION'),
            const SettingsRow(
              icon: Icons.check_circle_outline_rounded,
              title: 'Completed audio',
              value: '24 hours',
            ),
            const SettingsRow(
              icon: Icons.pending_outlined,
              title: 'Incomplete audio',
              value: '7 days',
            ),
            const SettingsSection('MICROPHONE'),
            SettingsRow(
              icon: connectionState == DeviceConnectionState.muted
                  ? Icons.mic_off_outlined
                  : Icons.mic_outlined,
              title: 'Current status',
              value: microphoneStatus,
            ),
            SettingsRow(
              icon: Icons.notes_rounded,
              title: 'Transcripts',
              subtitle: 'Review stored transcript text.',
              onTap: onOpenTranscripts == null
                  ? null
                  : () {
                      Navigator.of(context).popUntil((route) => route.isFirst);
                      onOpenTranscripts!();
                    },
            ),
          ],
        );
      },
    );
  }
}