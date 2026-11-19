import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'echo_nav_bar.dart';

/// A page with an iOS large title that collapses into a translucent bar on scroll.
class EchoLargeTitlePage extends StatelessWidget {
  const EchoLargeTitlePage({
    required this.title,
    required this.slivers,
    this.trailing,
    this.onRefresh,
    super.key,
  });

  final String title;
  final Widget? trailing;
  final List<Widget> slivers;

  /// Pull to refresh; without it there is no refresh control.
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    // Pushed pages get the bar as padding, tab roots as EchoShellInsets; never both.
    final bottom = math.max(
          MediaQuery.paddingOf(context).bottom,
          EchoShellInsets.bottomOf(context),
        ) +
        32;
    return Scaffold(
      backgroundColor: palette.background,
      body: CustomScrollView(
        // Bounce on every platform: the pull to refresh needs the overscroll.
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          CupertinoSliverNavigationBar(
            // A title that arrives late (a person's name once loaded) must replace the first
            key: ValueKey(title),
            largeTitle: Text(title),
            trailing: trailing,
            backgroundColor: palette.chrome,
            border:
                Border(bottom: BorderSide(color: palette.border, width: 0.5)),
          ),
          if (onRefresh != null)
            CupertinoSliverRefreshControl(onRefresh: onRefresh),
          ...slivers,
          SliverToBoxAdapter(child: SizedBox(height: bottom)),
        ],
      ),
    );
  }
}
