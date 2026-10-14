import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Building blocks shared by every list in the app, so loading, error and empty
/// states look and read the same everywhere.

/// A 44 pt section title with an optional trailing note ("+3 more", "Today").
final class SectionHeader extends StatelessWidget {
  const SectionHeader({required this.title, this.trailing, super.key});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleMedium),
            ),
            if (trailing != null)
              Text(
                trailing!,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: EchoPalette.of(context).text2,
                    ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A thin progress bar announced to screen readers.
final class SectionLoading extends StatelessWidget {
  const SectionLoading({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Semantics(
      liveRegion: true,
      label: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: LinearProgressIndicator(
          minHeight: 2,
          color: palette.blue,
          backgroundColor: palette.surface2,
        ),
      ),
    );
  }
}

/// An inline error with a Retry button.
final class SectionError extends StatelessWidget {
  const SectionError({
    required this.message,
    required this.retryKey,
    required this.onRetry,
    super.key,
  });

  final String message;
  final Key retryKey;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: message,
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: EchoPalette.of(context).text2,
                  ),
            ),
          ),
          SizedBox(
            height: 44,
            child: TextButton.icon(
              key: retryKey,
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry'),
            ),
          ),
        ],
      ),
    );
  }
}

/// A muted one-line message for an empty section.
final class SectionEmpty extends StatelessWidget {
  const SectionEmpty({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: EchoPalette.of(context).text2,
            ),
      ),
    );
  }
}

/// A centred icon, title and message filling a screen, still pull-to-refresh.
final class FullScreenMessage extends StatelessWidget {
  const FullScreenMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.onRefresh,
    this.actionKey,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Future<void> Function()? onRefresh;
  final Key? actionKey;
  final String? actionLabel;
  final Future<void> Function()? onAction;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final content = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 32, color: palette.text2),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.text2,
                        ),
                  ),
                  if (onAction != null) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 44,
                      child: TextButton(
                        key: actionKey,
                        onPressed: () => unawaited(onAction!()),
                        child: Text(actionLabel!),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
    final refresh = onRefresh;
    return refresh == null ? content : RefreshIndicator(onRefresh: refresh, child: content);
  }
}
