import 'package:flutter/material.dart';

import '../../models/device_status.dart';
import '../../theme/app_theme.dart';
import '../../widgets/device_pill.dart';
import '../../widgets/echo_device_mark.dart';
import '../../widgets/panel.dart';

/// The last setup step: how the user always sees, and stops, Echo listening.
final class PrivacyStep extends StatelessWidget {
  const PrivacyStep({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('You control listening', style: textTheme.headlineLarge),
        const SizedBox(height: 8),
        Text(
          'You always see when Echo listens, and you can stop it in a second.',
          style: textTheme.bodyMedium?.copyWith(color: palette.text2),
        ),
        const SizedBox(height: 28),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _PrivacyRow(
                sample: _Pill(DeviceConnectionState.listening),
                text:
                    'The pill at the top of Today and Ask glows blue while Echo listens.',
              ),
              Divider(height: 33, color: palette.border),
              const _PrivacyRow(
                sample: _Pill(DeviceConnectionState.muted),
                text: 'Hold the pill to mute. Hold it again to listen.',
              ),
              Divider(height: 33, color: palette.border),
              const _PrivacyRow(
                sample: EchoDeviceGlyph(size: 44),
                text:
                    'Or press the button on Echo itself. Its light turns off.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'What Echo hears is kept on your account and nowhere else. You can delete any '
          'conversation, or everything, from Settings.',
          style: textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// The pill as it looks in the app, not a control here.
final class _Pill extends StatelessWidget {
  const _Pill(this.state);

  final DeviceConnectionState state;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: DevicePill(
            status: DeviceStatus(connectionState: state, batteryPercent: 82)),
      ),
    );
  }
}

final class _PrivacyRow extends StatelessWidget {
  const _PrivacyRow({required this.sample, required this.text});

  final Widget sample;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
            width: 104,
            child: Align(alignment: Alignment.centerLeft, child: sample)),
        const SizedBox(width: 12),
        Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
      ],
    );
  }
}
