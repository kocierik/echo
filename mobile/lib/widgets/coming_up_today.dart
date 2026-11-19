import 'package:flutter/material.dart';

import '../models/today_insights.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import 'echo_grouped.dart';

/// An appointment of today from the iPhone's calendar.
@immutable
final class TodayEvent {
  const TodayEvent({required this.title, required this.start, this.end, this.allDay = false});

  /// The phone's events (`PhoneActionsService.upcomingEvents`) still on for [now]'s day:
  /// all-day ones first, then by time ([isLeftOn]).
  static List<TodayEvent> fromPhone(List<Map<String, Object?>> events, DateTime now) {
    DateTime? time(Object? value) => DateTime.tryParse(value as String? ?? '')?.toLocal();
    final kept = <TodayEvent>[];
    for (final event in events) {
      final title = (event['title'] as String? ?? '').trim();
      final start = time(event['start']);
      if (title.isEmpty || start == null) continue;
      final today = TodayEvent(
        title: title,
        start: start,
        end: time(event['end']),
        allDay: event['all_day'] == true,
      );
      if (today.isLeftOn(now)) kept.add(today);
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

  /// Local time; null when the phone did not say.
  final DateTime? end;
  final bool allDay;

  /// Still to show on [now]'s day: an all-day event covering it, one going on, or one to
  /// come; not one that is over or on another day.
  bool isLeftOn(DateTime now) {
    final today = dayOf(now);
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    if (!start.isBefore(tomorrow)) return false;
    if (allDay) return (end ?? DateTime(start.year, start.month, start.day + 1)).isAfter(today);
    final over = end;
    return over != null ? over.isAfter(now) : !start.isBefore(now);
  }

  /// It started and has not ended: "Now" instead of its time.
  bool isUnderWay(DateTime now) =>
      !allDay && start.isBefore(now) && (end?.isAfter(now) ?? false);
}

/// "Coming up today": what is still to come on the calendar; under the event that starts
/// within the hour, what was said last time. Nothing without events.
final class ComingUpTodayPanel extends StatelessWidget {
  const ComingUpTodayPanel({required this.events, this.recap, this.now, super.key});

  final List<TodayEvent> events;

  /// To say "Now" for an appointment going on.
  final DateTime? now;

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
    return EchoGroup(
      key: const Key('coming-up-today'),
      header: 'Coming up today',
      children: [
        for (final event in events)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 60,
                  child: Text(
                    event.allDay
                        ? 'All day'
                        : now != null && event.isUnderWay(now!)
                            ? 'Now'
                            : formatTime(event.start),
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
    );
  }
}
