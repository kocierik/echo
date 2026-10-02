import 'package:flutter/material.dart';

import '../models/segment.dart';
import '../theme/app_theme.dart';

final class TodayMemoryPreview extends StatelessWidget {
  const TodayMemoryPreview({
    required this.loading,
    required this.segment,
    required this.error,
    required this.onRetry,
    required this.onTap,
    required this.onViewAll,
    super.key,
  });

  final bool loading;
  final RecentSegment? segment;
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback? onTap;
  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return SizedBox(
      height: 174,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Recent memory',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: onViewAll,
                  child: const Text('View all'),
                ),
              ],
            ),
          ),
          Divider(color: palette.border),
          Expanded(child: _buildBody(context, palette)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, EchoPalette palette) {
    if (loading) {
      return Semantics(
        key: const Key('memory-loading'),
        liveRegion: true,
        label: 'Loading latest memory',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                minHeight: 2,
                color: palette.blue,
                backgroundColor: palette.surface2,
              ),
              const SizedBox(height: 18),
              FractionallySizedBox(
                widthFactor: 0.82,
                child: Container(height: 12, color: palette.surface2),
              ),
              const SizedBox(height: 10),
              FractionallySizedBox(
                widthFactor: 0.58,
                child: Container(height: 12, color: palette.surface2),
              ),
            ],
          ),
        ),
      );
    }

    if (error != null) {
      return Semantics(
        liveRegion: true,
        label: error,
        child: Row(
          children: [
            Expanded(
              child: Text(
                error!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: palette.text2,
                    ),
              ),
            ),
            SizedBox(
              height: 44,
              child: TextButton.icon(
                key: const Key('memory-retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry'),
              ),
            ),
          ],
        ),
      );
    }

    final memory = segment;
    if (memory == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'No completed memories yet.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: palette.text2,
              ),
        ),
      );
    }

    final excerpt = stripMemoryPrefix(memory.text ?? '');
    return Semantics(
      button: true,
      label: 'Open latest memory. $excerpt',
      child: InkWell(
        key: const Key('memory-content'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_formatTime(memory.recordedAt)}  ·  ${_speakerLabel(memory.speaker)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: palette.text2,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                excerpt,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String stripMemoryPrefix(String text) {
  return text
      .replaceFirst(
        RegExp(
          r'^\s*\[(?:you|others|tu|altri|self|other)\]\s*',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
}

String _formatTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _speakerLabel(String? speaker) {
  return switch (speaker?.toLowerCase()) {
    'self' => 'You',
    'other' => 'Someone else',
    _ => 'Unknown speaker',
  };
}