import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// How much of the bottom of a tab the floating navigation covers: lists and the
/// Ask composer keep this much space free. Zero outside the shell (and in tests).
final class EchoShellInsets extends InheritedWidget {
  const EchoShellInsets(
      {required this.bottom, required super.child, super.key});

  final double bottom;

  static double bottomOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EchoShellInsets>()?.bottom ??
      0;

  @override
  bool updateShouldNotify(EchoShellInsets oldWidget) =>
      bottom != oldWidget.bottom;
}

/// The graphite bar: Today on the left, Profile on the right and, in the middle,
/// the round Ask button. A tap on it opens Ask; held, Ask dictates until let go.
final class EchoNavBar extends StatelessWidget {
  const EchoNavBar({
    required this.selectedIndex,
    required this.onSelect,
    required this.onAskHold,
    this.dictating = false,
    super.key,
  });

  static const barHeight = 66.0;
  static const askSize = 76.0;

  /// Space the bar takes above the bottom edge (its height, the Ask button rising
  /// above it, and the gap below it).
  static const reserved = barHeight + 20 + 24;

  /// 0 Today, 1 Ask, 2 Library.
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// True when the Ask button starts being held, false when it is let go.
  final ValueChanged<bool> onAskHold;
  final bool dictating;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return SizedBox(
      height: barHeight + 30,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomCenter,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(barHeight / 2),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                height: barHeight,
                padding: const EdgeInsets.symmetric(horizontal: 28),
                decoration: BoxDecoration(
                  color: palette.chrome,
                  // shortcut: a uniform hairline (a top-only border cannot follow the pill's radius).
                  border: Border.all(color: palette.chromeLine, width: 0.5),
                  borderRadius: BorderRadius.circular(barHeight / 2),
                ),
                child: Row(
                  children: [
                    _Destination(
                      index: 0,
                      label: 'Today',
                      icon: CupertinoIcons.clock,
                      selected: selectedIndex == 0,
                      onSelect: onSelect,
                    ),
                    const Spacer(),
                    _Destination(
                      index: 2,
                      label: 'Library',
                      icon: CupertinoIcons.square_stack_3d_up,
                      selected: selectedIndex == 2,
                      onSelect: onSelect,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            child: AskButton(
              selected: selectedIndex == 1,
              dictating: dictating,
              onTap: () => onSelect(1),
              onHold: onAskHold,
            ),
          ),
        ],
      ),
    );
  }
}

final class _Destination extends StatelessWidget {
  const _Destination({
    required this.index,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onSelect,
  });

  final int index;
  final String label;
  final IconData icon;
  final bool selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final color = selected ? palette.onChrome : palette.onChromeMuted;
    return Semantics(
      key: Key('echo-nav-$index'),
      label: label,
      button: true,
      selected: selected,
      excludeSemantics: true,
      onTap: () => onSelect(index),
      child: InkResponse(
        onTap: () => onSelect(index),
        radius: 36,
        child: SizedBox(
          width: 72,
          height: EchoNavBar.barHeight,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The round, hardware-like Ask button. A press longer than [holdAfter] is a hold.
final class AskButton extends StatefulWidget {
  const AskButton({
    required this.selected,
    required this.dictating,
    required this.onTap,
    required this.onHold,
    super.key,
  });

  static const holdAfter = Duration(milliseconds: 300);

  final bool selected;
  final bool dictating;
  final VoidCallback onTap;
  final ValueChanged<bool> onHold;

  @override
  State<AskButton> createState() => _AskButtonState();
}

final class _AskButtonState extends State<AskButton> {
  Timer? _holdTimer;
  bool _holding = false;
  bool _pressed = false;

  void _down(PointerDownEvent _) {
    setState(() => _pressed = true);
    _holdTimer = Timer(AskButton.holdAfter, () {
      _holding = true;
      unawaited(HapticFeedback.mediumImpact());
      widget.onHold(true);
    });
  }

  void _up(PointerEvent event) {
    _holdTimer?.cancel();
    setState(() => _pressed = false);
    if (_holding) {
      _holding = false;
      widget.onHold(false);
    } else if (event is PointerUpEvent) {
      widget.onTap();
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    if (_holding) widget.onHold(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final live = widget.dictating || _holding;
    final ring = live || widget.selected
        ? palette.onAccent.withValues(alpha: 0.6)
        : palette.accent;
    return Semantics(
      key: const Key('echo-nav-1'),
      label: live ? 'Dictating. Let go to stop' : 'Ask Echo',
      hint: 'Hold to dictate',
      button: true,
      selected: widget.selected,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: Listener(
        key: const Key('echo-ask-button'),
        onPointerDown: _down,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: AnimatedScale(
          scale: _pressed ? 0.94 : 1,
          duration: const Duration(milliseconds: 90),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: EchoNavBar.askSize,
            height: EchoNavBar.askSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: palette.accent,
              boxShadow: [
                BoxShadow(color: palette.background, spreadRadius: 5),
                if (live)
                  BoxShadow(
                    color: palette.accent.withValues(alpha: 0.28),
                    spreadRadius: 14,
                  ),
              ],
            ),
            alignment: Alignment.center,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: ring, width: 2),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.mic_none_rounded,
                  size: 26, color: palette.onAccent),
            ),
          ),
        ),
      ),
    );
  }
}
