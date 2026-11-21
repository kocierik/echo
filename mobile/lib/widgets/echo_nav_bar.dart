import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// How much of the bottom of a tab the navigation bar covers: lists and the
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

/// The translucent bar on the bottom edge: Today, Ask and Library. Dictation lives in
/// Ask's composer (its microphone), not here.
final class EchoNavBar extends StatelessWidget {
  const EchoNavBar({
    required this.selectedIndex,
    required this.onSelect,
    super.key,
  });

  /// The bar's own height, above the home indicator.
  static const barHeight = 52.0;

  /// 0 Today, 1 Ask, 2 Library.
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.bar,
            border: Border(top: BorderSide(color: palette.border, width: 0.5)),
          ),
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
            child: SizedBox(
              height: barHeight,
              // As iOS's tab bar: the labels grow only a little with the text size
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.2,
                child: Row(
                children: [
                  for (final (index, label, icon) in const [
                    (0, 'Today', CupertinoIcons.clock),
                    (1, 'Ask', CupertinoIcons.chat_bubble),
                    (2, 'Library', CupertinoIcons.square_stack_3d_up),
                  ])
                    Expanded(
                      child: _Destination(
                        index: index,
                        label: label,
                        icon: icon,
                        selected: selectedIndex == index,
                        onSelect: onSelect,
                      ),
                    ),
                ],
              ),
              ),
            ),
          ),
        ),
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
    final color = selected ? palette.accent : palette.text2;
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
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 24, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
