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

/// A titled panel of rows that bring their own side padding (tasks, events,
/// conversations), with the margin of a page.
final class PanelSection extends StatelessWidget {
  const PanelSection({
    required this.title,
    required this.children,
    this.trailing,
    super.key,
  });

  final String title;

  /// A muted note on the right: a count, usually.
  final String? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Panel(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: PanelHeader(title: title, trailing: trailing),
            ),
            const SizedBox(height: 4),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A row of a long list drawn as one panel: the first and the last row round
/// its corners, a hairline separates the others. Keeps the list lazy.
final class PanelListRow extends StatelessWidget {
  const PanelListRow({
    required this.index,
    required this.count,
    required this.child,
    super.key,
  });

  final int index;
  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    const round = Radius.circular(AppTheme.panelRadius);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: palette.surface,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.vertical(
          top: index == 0 ? round : Radius.zero,
          bottom: index == count - 1 ? round : Radius.zero,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (index > 0) Divider(height: 1, indent: 16, endIndent: 16, color: palette.border),
            child,
          ],
        ),
      ),
    );
  }
}
