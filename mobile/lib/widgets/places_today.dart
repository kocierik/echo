import 'package:flutter/material.dart';

import '../models/place.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import 'panel.dart';

/// The stays on [day], oldest first: the ones that began on it, and the ones from before
/// that ended on it or are still going (the night at home).
List<PlaceVisit> visitsOn(List<PlaceVisit> visits, DateTime day) {
  final date = dayOf(day);
  final next = DateTime(date.year, date.month, date.day + 1);
  return [
    for (final visit in visits)
      if (visit.arrivedAt.isBefore(next) && (visit.leftAt?.isAfter(date) ?? true)) visit,
  ]..sort((a, b) => a.arrivedAt.compareTo(b.arrivedAt));
}

/// "Where you've been": today's last [shown] stays with their times; a tap opens one in
/// the phone's maps, See all opens Places visited (the rest). Nothing without stays.
final class PlacesTodayPanel extends StatelessWidget {
  const PlacesTodayPanel({
    required this.visits,
    required this.onOpen,
    required this.onSeeAll,
    this.now,
    super.key,
  });

  /// A day of errands is a long list: the latest ones, the others in See all.
  static const shown = 3;

  final List<PlaceVisit> visits;
  final void Function(PlaceVisit visit) onOpen;
  final VoidCallback onSeeAll;

  /// Today, for a stay from before it; the phone's time by default.
  final DateTime? now;

  /// "09:00–11:00", "09:00" while there; from before today, "Until 07:30" or "Since
  /// yesterday".
  String _when(PlaceVisit visit, DateTime today) {
    final left = visit.leftAt;
    if (!visit.arrivedAt.isBefore(today)) {
      return left == null
          ? formatTime(visit.arrivedAt)
          : '${formatTime(visit.arrivedAt)}–${formatTime(left)}';
    }
    if (left != null) return 'Until ${formatTime(left)}';
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    return dayOf(visit.arrivedAt) == yesterday
        ? 'Since yesterday'
        : 'Since ${shortDate(visit.arrivedAt.toLocal())}';
  }

  @override
  Widget build(BuildContext context) {
    if (visits.isEmpty) return const SizedBox.shrink();
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final today = dayOf(now ?? DateTime.now());
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Panel(
        key: const Key('places-today'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PanelHeader(
              title: "Where you've been",
              actionLabel: 'See all',
              onAction: onSeeAll,
              actionKey: const Key('places-see-all'),
            ),
            for (final visit in visits.skip(visits.length > shown ? visits.length - shown : 0))
              InkWell(
                key: Key('place-${visit.id}'),
                onTap: () => onOpen(visit),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 96,
                        child: Text(
                          _when(visit, today),
                          style: textTheme.labelMedium?.copyWith(color: palette.accent),
                        ),
                      ),
                      Expanded(child: Text(visit.label, style: textTheme.bodyMedium)),
                      Icon(Icons.map_outlined, size: 18, color: palette.text2),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
