import 'package:flutter/material.dart';

import '../models/today_insights.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import 'panel.dart';
import 'sections.dart';

/// The digest of the latest finished day, labelled with its day. A tap shows
/// all of it.
final class DigestSection extends StatefulWidget {
  const DigestSection({
    required this.loading,
    required this.summary,
    required this.error,
    required this.onRetry,
    required this.now,
    super.key,
  });

  final bool loading;
  final DailySummary? summary;
  final String? error;
  final VoidCallback onRetry;
  final DateTime now;

  @override
  State<DigestSection> createState() => _DigestSectionState();
}

final class _DigestSectionState extends State<DigestSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final digest = widget.summary;
    final textTheme = Theme.of(context).textTheme;
    return Panel(
      key: const Key('daily-summary'),
      onTap: digest == null ? null : () => setState(() => _expanded = !_expanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelHeader(
            title: digest == null ? 'Daily summary' : dayLabel(digest.date, widget.now),
          ),
          const SizedBox(height: 6),
          if (widget.loading)
            const SectionLoading(key: Key('summary-loading'), label: 'Loading the daily summary')
          else if (widget.error != null)
            SectionError(
              message: widget.error!,
              retryKey: const Key('summary-retry'),
              onRetry: widget.onRetry,
            )
          else if (digest == null)
            Text(
              'Echo writes a summary of each day overnight.',
              style: textTheme.bodyMedium?.copyWith(color: EchoPalette.of(context).text2),
            )
          else
            Text(
              digest.summary,
              key: const Key('summary-content'),
              maxLines: _expanded ? null : 4,
              overflow: _expanded ? null : TextOverflow.ellipsis,
              style: textTheme.bodyMedium,
            ),
        ],
      ),
    );
  }
}

/// The latest weekly summary: what the week was about, its highlights (on a
/// tap), who came up.
final class WeeklySummarySection extends StatefulWidget {
  const WeeklySummarySection({required this.week, required this.now, super.key});

  final WeeklySummary week;
  final DateTime now;

  @override
  State<WeeklySummarySection> createState() => _WeeklySummarySectionState();
}

final class _WeeklySummarySectionState extends State<WeeklySummarySection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final week = widget.week;
    final textTheme = Theme.of(context).textTheme;
    final palette = EchoPalette.of(context);
    return Panel(
      key: const Key('weekly-summary'),
      onTap: () => setState(() => _expanded = !_expanded),
      child: Column(
        key: const Key('weekly-summary-content'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelHeader(title: weekLabel(week.weekStart, widget.now)),
          const SizedBox(height: 6),
          Text(
            week.summary,
            maxLines: _expanded ? null : 4,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: textTheme.bodyMedium,
          ),
          if (_expanded)
            for (final highlight in week.highlights)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('• $highlight', style: textTheme.bodyMedium),
              ),
          if (week.people.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'With ${week.people.take(4).join(', ')}',
                style: textTheme.bodySmall?.copyWith(color: palette.text2),
              ),
            ),
        ],
      ),
    );
  }
}

/// "This week", "Last week", or "Week of Oct 5".
String weekLabel(DateTime weekStart, DateTime now) {
  final today = dayOf(now);
  // Calendar days, not 24-hour steps: right across a change to summer time
  final monday = DateTime(today.year, today.month, today.day - (today.weekday - 1));
  final start = dayOf(weekStart);
  if (start == monday) return 'This week';
  if (start == DateTime(monday.year, monday.month, monday.day - 7)) return 'Last week';
  return 'Week of ${shortDate(weekStart)}';
}
