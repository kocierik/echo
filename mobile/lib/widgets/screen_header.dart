import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A tab's title: a muted line above it (optional), the wide bold title, and the
/// actions on the right (the device pill last).
final class ScreenHeader extends StatelessWidget {
  const ScreenHeader({
    required this.title,
    this.overline,
    this.actions = const [],
    this.compact = false,
    super.key,
  });

  final String title;

  /// "Thursday" above "15 October".
  final String? overline;
  final List<Widget> actions;

  /// A smaller title, for a line rather than a name ("Good afternoon" on Today).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (overline != null)
                      Text(
                        overline!,
                        style: textTheme.bodyMedium
                            ?.copyWith(color: palette.text2),
                      ),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: compact ? textTheme.displaySmall : textTheme.displayLarge,
                    ),
                  ],
                ),
              ),
            ),
            // On a narrow screen the actions take at most three quarters and
            // the pill shortens its label
            ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: constraints.maxWidth * 0.75),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final action in actions) ...[
                    const SizedBox(width: 8),
                    Flexible(child: action),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A round 44 pt button on the ground, for a header ("Past chats", "New chat").
final class HeaderIconButton extends StatelessWidget {
  const HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return SizedBox.square(
      dimension: 44,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        style: IconButton.styleFrom(backgroundColor: palette.surface),
        icon: Icon(icon, size: 20, color: palette.text),
      ),
    );
  }
}
