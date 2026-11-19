import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The wearable as Echo draws it: a graphite disc, its inner ring and the LED near
/// the top. [breathing] makes the LED's glow rise and fall (still with reduced
/// motion).
final class EchoDeviceMark extends StatefulWidget {
  const EchoDeviceMark({this.size = 120, this.breathing = false, super.key});

  final double size;
  final bool breathing;

  @override
  State<EchoDeviceMark> createState() => _EchoDeviceMarkState();
}

final class _EchoDeviceMarkState extends State<EchoDeviceMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant EchoDeviceMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final moving = widget.breathing && !MediaQuery.disableAnimationsOf(context);
    if (moving && !_breath.isAnimating) {
      _breath.repeat();
    } else if (!moving && _breath.isAnimating) {
      _breath.stop();
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _breath,
        builder: (context, _) {
          // 0 → 1 → 0 over a breath; a fixed middle when still
          final glow = _breath.isAnimating
              ? (1 - math.cos(_breath.value * 2 * math.pi)) / 2
              : 0.5;
          return EchoDeviceGlyph(size: widget.size, glow: glow);
        },
      ),
    );
  }
}

/// One frame of [EchoDeviceMark]: [glow] from 0 (dim) to 1 (bright).
final class EchoDeviceGlyph extends StatelessWidget {
  const EchoDeviceGlyph({required this.size, this.glow = 0.5, super.key});

  final double size;
  final double glow;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final led = size * 0.09;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: dark ? palette.bar : palette.surface2,
        shape: BoxShape.circle,
      ),
      child: Container(
        width: size * 0.76,
        height: size * 0.76,
        alignment: Alignment.topCenter,
        padding: EdgeInsets.only(top: size * 0.12),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: palette.border, width: 2),
        ),
        child: Container(
          width: led,
          height: led,
          decoration: BoxDecoration(
            color: palette.accent,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                  color: palette.accentSoft,
                  spreadRadius: led * (0.4 + 0.3 * glow)),
              BoxShadow(
                color: palette.accent.withValues(alpha: 0.25 + 0.3 * glow),
                blurRadius: led * (1.4 + 1.6 * glow),
                spreadRadius: led * 0.3 * glow,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
