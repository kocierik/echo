import 'package:flutter/material.dart';

import '../models/today_insights.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import 'panel.dart';

/// An appointment of today from the iPhone's calendar.
@immutable
final class TodayEvent {
  const TodayEvent({required this.title, required this.start, this.allDay = false});

  /// The phone's events (`PhoneActionsService.upcomingEvents`) still to come on [now]'s
  /// day: all-day ones first, then by time; the ones that started are left out.
  static List<TodayEvent> fromPhone(List<Map<String, Object?>> events, DateTime now) {
    final today = dayOf(now);
    final kept = <TodayEvent>[];
    for (final event in events) {
      final title = (event['title'] as String? ?? '').trim();
      final start = DateTime.tryParse(event['start'] as String? ?? '')?.toLocal();
      if (title.isEmpty || start == null || dayOf(start) != today) continue;
      final allDay = event['all_day'] == true;
      if (!allDay && start.isBefore(now)) continue;
      kept.add(TodayEvent(title: title, start: start, allDay: allDay));
    }
    kept.sort((a, b) {
      if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
      return a.start.compareTo(b.start);
    });
    return kept;
  }

  final String title;

  /// Local time.
  final DateTime start;
  final bool allDay;
}

/// "Coming up today": what is still to come on the calendar; under the event that starts
/// within the hour, what was said last time. Nothing without events.
final class ComingUpTodayPanel extends StatelessWidget {
  const ComingUpTodayPanel({required this.events, this.recap, super.key});

  final List<TodayEvent> events;

  /// The event within the hour and its recap (`POST /api/notifications/coming-up`).
  final ComingUp? recap;

  bool _recapFor(TodayEvent event) {
    final soon = recap;
    return soon != null &&
        soon.recap != null &&
        soon.title == event.title &&
        soon.start.difference(event.start).inMinutes == 0;
  }

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) return const SizedBox.shrink();
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Panel(
        key: const Key('coming-up-today'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PanelHeader(title: 'Coming up today'),
            for (final event in events)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 60,
                      child: Text(
                        event.allDay ? 'All day' : formatTime(event.start),
                        style: textTheme.labelMedium?.copyWith(color: palette.accent),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(event.title, style: textTheme.bodyMedium),
                          if (_recapFor(event)) ...[
                            const SizedBox(height: 2),
                            Text(
                              recap!.recap!,
                              style: textTheme.bodySmall?.copyWith(color: palette.text2),
                            ),
                          ],
                        ],
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
