import 'package:flutter/material.dart';

import '../models/place.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import 'panel.dart';

/// The stays that began on [day], oldest first.
List<PlaceVisit> visitsOn(List<PlaceVisit> visits, DateTime day) {
  final date = dayOf(day);
  return [
    for (final visit in visits)
      if (dayOf(visit.arrivedAt) == date) visit,
  ]..sort((a, b) => a.arrivedAt.compareTo(b.arrivedAt));
}

/// "Where you've been": today's stays with their times; a tap opens one in the phone's
/// maps, See all opens Places visited. Nothing without stays.
final class PlacesTodayPanel extends StatelessWidget {
  const PlacesTodayPanel({
    required this.visits,
    required this.onOpen,
    required this.onSeeAll,
    super.key,
  });

  final List<PlaceVisit> visits;
  final void Function(PlaceVisit visit) onOpen;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    if (visits.isEmpty) return const SizedBox.shrink();
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
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
            for (final visit in visits)
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
                          visit.leftAt == null
                              ? formatTime(visit.arrivedAt)
                              : '${formatTime(visit.arrivedAt)}–${formatTime(visit.leftAt!)}',
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
