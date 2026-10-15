import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A panel on the ground: the building block of every screen.
final class Panel extends StatelessWidget {
  const Panel({
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    super.key,
  });

  final Widget child;

  /// Defaults to the palette's surface.
  final Color? color;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppTheme.panelRadius);
    return Material(
      color: color ?? EchoPalette.of(context).surface,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// A panel's title row: the title, and an optional link or note on the right.
final class PanelHeader extends StatelessWidget {
  const PanelHeader({
    required this.title,
    this.trailing,
    this.actionLabel,
    this.onAction,
    this.actionKey,
    super.key,
  });

  final String title;

  /// A muted note ("3 conversations, 51 min").
  final String? trailing;

  /// A link ("See all"), when [onAction] is set.
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // Title and note share the row; a long note wraps on its side
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Semantics(
            header: true,
            child: Text(title, style: textTheme.titleMedium),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 12),
          Flexible(
            child: Text(trailing!, textAlign: TextAlign.end, style: textTheme.bodySmall),
          ),
        ],
        if (actionLabel != null && onAction != null)
          TextButton(
            key: actionKey,
            onPressed: onAction,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.only(left: 12),
              textStyle: textTheme.labelLarge?.copyWith(fontSize: 14),
            ),
            child: Text(actionLabel!),
          ),
      ],
    );
  }
}
