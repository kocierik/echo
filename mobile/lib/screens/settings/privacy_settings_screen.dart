import 'package:flutter/material.dart';

import '../../models/device_status.dart';
import '../../services/api/api_exception.dart';
import '../../services/api/api_service.dart';
import '../../services/app/app_controller.dart';
import '../../services/app/sharing.dart';
import 'settings_components.dart';
import '../navigation.dart';

class PrivacySettingsScreen extends StatelessWidget {
  const PrivacySettingsScreen({
    required this.appController,
    this.onOpenTranscripts,
    this.exportData,
    this.sharing = const SystemSharing(),
    this.clock = DateTime.now,
    super.key,
  });

  final AppController appController;
  final VoidCallback? onOpenTranscripts;

  /// The export file's bytes (the server's GET /export); a real ApiService by default.
  final Future<List<int>> Function()? exportData;
  final Sharing sharing;
  final DateTime Function() clock;

  Future<void> _export(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Preparing your data…')));
    final ownedApi = exportData == null ? ApiService() : null;
    try {
      final bytes = await (exportData ?? ownedApi!.exportData)();
      final day = clock().toIso8601String().substring(0, 10);
      await sharing.shareFile('echo-export-$day.json', bytes, subject: 'Echo export');
      messenger.hideCurrentSnackBar();
    } catch (error) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(userMessage(error, 'Could not export your data.'))));
    } finally {
      ownedApi?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: appController,
      builder: (context, state, child) {
        final connectionState = state.device.connectionState;
        final microphoneStatus = switch (connectionState) {
          DeviceConnectionState.muted => 'Muted',
          DeviceConnectionState.listening => 'Listening',
          DeviceConnectionState.turningOff || DeviceConnectionState.off => 'Off',
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
            // Deferred by the plan's budget: kept until it is transcribed (Profile → Plan)
            const SettingsRow(
              icon: Icons.hourglass_empty_rounded,
              title: 'Waiting audio',
              subtitle: 'Speech past the plan\'s budget.',
              value: 'Until transcribed',
            ),
            const SettingsSection('MICROPHONE'),
            SettingsRow(
              icon: connectionState == DeviceConnectionState.muted
                  ? Icons.mic_off_outlined
                  : Icons.mic_outlined,
              title: 'Current status',
              value: microphoneStatus,
            ),
            const SettingsSection('YOUR DATA'),
            SettingsRow(
              key: const Key('privacy-export'),
              icon: Icons.download_rounded,
              title: 'Export my data',
              subtitle: 'Conversations, transcripts, tasks, people and chats, as one file.',
              onTap: () => _export(context),
            ),
            SettingsRow(
              icon: Icons.notes_rounded,
              title: 'Transcripts',
              subtitle: 'Review stored transcript text.',
              onTap: onOpenTranscripts == null
                  ? null
                  : () {
                      popToTabs(context);
                      onOpenTranscripts!();
                    },
            ),
          ],
        );
      },
    );
  }
}