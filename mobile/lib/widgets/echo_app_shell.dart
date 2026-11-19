import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';

import '../models/app_view_state.dart';
import '../theme/app_theme.dart';
import 'echo_nav_bar.dart';
import 'offline_banner.dart';

/// The three tabs under the floating navigation. Each tab draws its own header
/// (with the device pill); the bar hides while the keyboard is up.
final class EchoAppShell extends StatefulWidget {
  const EchoAppShell({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.onAskHold,
    required this.children,
    required this.navigatorKeys,
    this.dictating = false,
    super.key,
  })  : assert(selectedIndex >= 0 && selectedIndex < AppViewState.tabCount),
        assert(children.length == AppViewState.tabCount),
        assert(navigatorKeys.length == AppViewState.tabCount);

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final ValueChanged<bool> onAskHold;
  final bool dictating;
  final List<Widget> children;

  /// One navigator per tab: pages opened in a tab stay in it, under the bar.
  final List<GlobalKey<NavigatorState>> navigatorKeys;

  @override
  State<EchoAppShell> createState() => _EchoAppShellState();
}

final class _EchoAppShellState extends State<EchoAppShell> {
  late final _observers = [
    for (var i = 0; i < AppViewState.tabCount; i++) _TabObserver(_refresh),
  ];

  /// Whether the open tab has a page to close: only then does back stay in the app.
  bool _canPop = false;

  void _refresh() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final can =
          widget.navigatorKeys[widget.selectedIndex].currentState?.canPop() ??
              false;
      if (can != _canPop) setState(() => _canPop = can);
    });
  }

  @override
  void didUpdateWidget(EchoAppShell old) {
    super.didUpdateWidget(old);
    _refresh();
  }

  void _select(int index) {
    // Tapping the open tab again goes back to its first page
    if (index == widget.selectedIndex) {
      widget.navigatorKeys[index].currentState
          ?.popUntil((route) => route.isFirst);
    }
    widget.onDestinationSelected(index);
  }

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
                      // Pushed pages clear the bar through their own bottom padding
                      child: Builder(
                        builder: (context) => MediaQuery(
                          data: MediaQuery.of(context).copyWith(
                            padding: MediaQuery.of(context)
                                .padding
                                .copyWith(bottom: covered),
                          ),
                          child: NavigatorPopHandler(
                            enabled: _canPop,
                            onPopWithResult: (_) => widget
                                .navigatorKeys[widget.selectedIndex]
                                .currentState
                                ?.maybePop(),
                            child: _TabChildren(
                              children: widget.children,
                              covered: covered,
                              child: IndexedStack(
                                index: widget.selectedIndex,
                                sizing: StackFit.expand,
                                children: [
                                  for (var i = 0;
                                      i < widget.children.length;
                                      i++)
                                    Navigator(
                                      key: widget.navigatorKeys[i],
                                      observers: [_observers[i]],
                                      onGenerateRoute: (_) =>
                                          CupertinoPageRoute<void>(
                                        builder: (context) =>
                                            _TabChildren.root(context, i),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
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
                        selectedIndex: widget.selectedIndex,
                        onSelect: _select,
                        onAskHold: widget.onAskHold,
                        dictating: widget.dictating,
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

/// Hands a tab's current child to its first route, so it rebuilds with the shell.
final class _TabChildren extends InheritedWidget {
  const _TabChildren({
    required this.children,
    required this.covered,
    required super.child,
  });

  final List<Widget> children;
  final double covered;

  /// A tab's root page: the bar's height is an inset, not padding.
  static Widget root(BuildContext context, int index) {
    final tabs = context.dependOnInheritedWidgetOfExactType<_TabChildren>()!;
    return MediaQuery.removePadding(
      context: context,
      removeBottom: true,
      child: EchoShellInsets(bottom: tabs.covered, child: tabs.children[index]),
    );
  }

  @override
  bool updateShouldNotify(_TabChildren old) => true;
}

/// Tells the shell when a tab's pages come and go.
final class _TabObserver extends NavigatorObserver {
  _TabObserver(this.changed);

  final VoidCallback changed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changed();
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => changed();
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changed();
}
