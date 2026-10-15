import 'package:flutter/material.dart';

import '../services/api/response_cache.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';

/// "Offline · updated 14:32" while the screens show the phone's copy; nothing otherwise.
final class OfflineBanner extends StatelessWidget {
  const OfflineBanner({this.since, this.now, super.key});

  /// Defaults to the app-wide [offlineDataSince].
  final ValueNotifier<DateTime?>? since;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DateTime?>(
      valueListenable: since ?? offlineDataSince,
      builder: (context, savedAt, child) {
        if (savedAt == null) return const SizedBox.shrink();
        final palette = EchoPalette.of(context);
        final local = savedAt.toLocal();
        final today = dayOf((now ?? DateTime.now)());
        final when = dayOf(local) == today
            ? formatTime(local)
            : '${dayLabel(local, today)} ${formatTime(local)}';
        return Semantics(
          liveRegion: true,
          child: Container(
            key: const Key('offline-banner'),
            width: double.infinity,
            color: palette.amber.withValues(alpha: 0.16),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.cloud_off_rounded, size: 16, color: palette.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Offline · updated $when',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
