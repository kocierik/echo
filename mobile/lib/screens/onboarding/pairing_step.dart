import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/echo_device_mark.dart';

final class PairingStep extends StatelessWidget {
  const PairingStep({
    required this.busy,
    required this.paired,
    super.key,
  });

  final bool busy;
  final bool paired;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final status = paired
        ? 'Echo paired and ready'
        : busy
            ? 'Looking for Echo nearby...'
            : 'Turn it on and keep it close to the phone. Its light blinks while it waits.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Pair your Echo', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        Semantics(
          liveRegion: true,
          child: Text(
            status,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: paired ? palette.green : palette.text2,
                ),
          ),
        ),
        const SizedBox(height: 28),
        Center(
          child: SizedBox.square(
            dimension: 200,
            child: Stack(
              alignment: Alignment.center,
              children: [
                _Ring(size: 200, color: palette.border),
                EchoDeviceMark(size: 112, breathing: !paired),
                if (paired)
                  Positioned(
                    right: 36,
                    bottom: 36,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(color: palette.green, shape: BoxShape.circle),
                      child: Icon(Icons.check_rounded, color: palette.background, size: 22),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 28),
        const _PairingNote(
          icon: Icons.bluetooth_searching_rounded,
          text: 'Pairing may open a system confirmation.',
        ),
        const SizedBox(height: 8),
        const _PairingNote(
          icon: Icons.schedule_rounded,
          text: 'No Echo with you? Pair it later from Settings.',
        ),
      ],
    );
  }
}

final class _Ring extends StatelessWidget {
  const _Ring({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color),
      ),
    );
  }
}

final class _PairingNote extends StatelessWidget {
  const _PairingNote({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Row(
      children: [
        SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 20, color: palette.text2),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
      ],
    );
  }
}