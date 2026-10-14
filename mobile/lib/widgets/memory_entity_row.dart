import 'package:flutter/material.dart';

import '../models/memory.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';

IconData entityIcon(String type) => switch (type) {
      'person' => Icons.person_outline_rounded,
      'task' => Icons.check_circle_outline_rounded,
      'event' => Icons.event_outlined,
      'idea' => Icons.lightbulb_outline_rounded,
      _ => Icons.sticky_note_2_outlined,
    };

String entityTypeName(String type) => switch (type) {
      'person' => 'Person',
      'task' => 'Task',
      'event' => 'Event',
      'idea' => 'Idea',
      _ => 'Note',
    };

/// "Thu, Oct 15 at 15:00" for an event, or null without a valid date.
String? eventWhen(MemoryEntity entity, DateTime now) {
  final date = DateTime.tryParse(entity.eventDate ?? '');
  if (date == null) return null;
  final time = entity.eventTime;
  final day = dayLabel(date, now);
  return time == null || time.isEmpty ? day : '$day at $time';
}

/// One extracted thing: an icon for its type, its name, and below either the
/// event day, its content, or the sentence it came from.
final class MemoryEntityRow extends StatelessWidget {
  const MemoryEntityRow({
    required this.entity,
    this.onTap,
    this.onAddToCalendar,
    this.now,
    super.key,
  });

  final MemoryEntity entity;
  final VoidCallback? onTap;

  /// For events: adds it to the calendar (through Ask).
  final VoidCallback? onAddToCalendar;

  /// Injectable "now" for tests.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final detail = entity.type == 'event'
        ? eventWhen(entity, now ?? DateTime.now()) ?? entity.content
        : entity.content;
    final source = entity.sourceText;

    final row = Semantics(
      button: onTap != null,
      label: [
        entityTypeName(entity.type),
        entity.name,
        if (detail != null) detail,
        if (source != null) 'From: ${cleanTranscript(source)}',
      ].join('. '),
      excludeSemantics: true,
      child: InkWell(
        key: Key('entity-${entity.id}'),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 10, onAddToCalendar == null ? 20 : 0, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(entityIcon(entity.type), size: 20, color: palette.text2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entity.name, style: textTheme.bodyMedium?.copyWith(height: 1.35)),
                    if (detail != null)
                      Text(
                        detail,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall,
                      ),
                    if (source != null) SourceQuote(text: source),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final addToCalendar = onAddToCalendar;
    if (addToCalendar == null) return row;
    // Outside the row's summary label, so screen readers reach the button too
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: row),
        Padding(
          padding: const EdgeInsets.only(top: 4, right: 8),
          child: IconButton(
            key: Key('entity-calendar-${entity.id}'),
            tooltip: 'Add "${entity.name}" to calendar',
            onPressed: addToCalendar,
            icon: Icon(Icons.event_available_outlined, color: palette.blue),
          ),
        ),
      ],
    );
  }
}

/// The transcript sentence something was extracted from, quoted.
final class SourceQuote extends StatelessWidget {
  const SourceQuote({required this.text, this.maxLines = 2, super.key});

  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '“${cleanTranscript(text)}”',
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 13,
              fontStyle: FontStyle.italic,
            ),
      ),
    );
  }
}
