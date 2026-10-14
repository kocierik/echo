import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

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
            : 'Keep Echo charged, awake, and close to this phone.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: SizedBox(
            width: 176,
            height: 176,
            child: Stack(
              alignment: Alignment.center,
              children: [
                _Ring(size: 176, color: palette.border),
                _Ring(size: 126, color: palette.border),
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: palette.surface2,
                    shape: BoxShape.circle,
                    border: Border.all(color: palette.blue, width: 2),
                  ),
                  child: Icon(
                    paired ? Icons.check_rounded : Icons.watch_outlined,
                    size: 34,
                    color: paired ? palette.green : palette.blue,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 28),
        Text('Pair your Echo', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 8),
        Semantics(
          liveRegion: true,
          child: Text(
            status,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: palette.text2,
                ),
          ),
        ),
        const SizedBox(height: 24),
        const _PairingNote(
          icon: Icons.bluetooth_searching_rounded,
          text: 'Pairing may open a system confirmation.',
        ),
        const SizedBox(height: 12),
        const _PairingNote(
          icon: Icons.lock_outline_rounded,
          text: 'The saved device identity enables secure reconnects.',
        ),
        const SizedBox(height: 12),
        const _PairingNote(
          icon: Icons.schedule_rounded,
          text: 'No Echo with you? Skip for now and pair it later in Settings > Device.',
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