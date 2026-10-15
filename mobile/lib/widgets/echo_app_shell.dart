import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/app_view_state.dart';
import '../theme/app_theme.dart';
import 'echo_nav_bar.dart';
import 'offline_banner.dart';

/// The three tabs under the floating navigation. Each tab draws its own header
/// (with the device pill); the bar hides while the keyboard is up.
final class EchoAppShell extends StatelessWidget {
  const EchoAppShell({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.onAskHold,
    required this.children,
    this.dictating = false,
    super.key,
  })  : assert(selectedIndex >= 0 && selectedIndex < AppViewState.tabCount),
        assert(children.length == AppViewState.tabCount);

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final ValueChanged<bool> onAskHold;
  final bool dictating;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final media = MediaQuery.of(context);
    final keyboardUp = media.viewInsets.bottom > 0;
    // The bar sits just above the home indicator (or 16 pt from the edge)
    final barBottom = media.padding.bottom > 0
        ? math.max(media.padding.bottom - 6, 12.0)
        : 16.0;
    final covered =
        keyboardUp ? 0.0 : barBottom + EchoNavBar.barHeight + 30 + 8;
    return ColoredBox(
      color: palette.background,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const OfflineBanner(),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: MediaQuery.removePadding(
                      context: context,
                      removeBottom: true,
                      child: EchoShellInsets(
                        bottom: covered,
                        child: IndexedStack(
                          index: selectedIndex,
                          sizing: StackFit.expand,
                          children: children,
                        ),
                      ),
                    ),
                  ),
                  if (!keyboardUp)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: barBottom,
                      child: EchoNavBar(
                        selectedIndex: selectedIndex,
                        onSelect: onDestinationSelected,
                        onAskHold: onAskHold,
                        dictating: dictating,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
