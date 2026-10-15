import 'package:flutter/material.dart';

import '../models/memory.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';

/// One conversation in a list: emoji, title, two lines of summary, time and
/// duration, people and tasks. Live and processing conversations say so.
final class ConversationCardTile extends StatelessWidget {
  const ConversationCardTile({
    required this.conversation,
    required this.onTap,
    this.dayFrom,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    super.key,
  });

  final ConversationCard conversation;
  final VoidCallback onTap;

  /// Outside a day-grouped list: "now", to say the day too ("Yesterday · 10:00").
  final DateTime? dayFrom;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final c = conversation;
    final title = conversationTitle(c);
    final summary = c.summary;
    final meta = _meta(c, dayFrom);

    return Semantics(
      button: true,
      label: _semanticLabel(c, title, meta),
      excludeSemantics: true,
      child: InkWell(
        key: Key('conversation-${c.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: padding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConversationEmoji(emoji: c.emoji),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(height: 1.3),
                    ),
                    if (summary != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (c.isOpen)
                          _StateBadge(label: 'Live', color: palette.green, dot: true)
                        else if (c.isProcessing)
                          _StateBadge(label: 'Processing', color: palette.amber),
                        Text(meta, style: _metaStyle(context)),
                        if (c.people.isNotEmpty)
                          _IconText(
                            icon: Icons.person_outline_rounded,
                            text: c.people.join(', '),
                          ),
                        if (c.taskCount > 0)
                          _IconText(
                            icon: Icons.check_circle_outline_rounded,
                            text: c.taskCount == 1 ? '1 task' : '${c.taskCount} tasks',
                          ),
                        if (c.photoCount > 0)
                          _IconText(
                            icon: Icons.photo_camera_outlined,
                            text: c.photoCount == 1 ? '1 photo' : '${c.photoCount} photos',
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _meta(ConversationCard c, DateTime? now) {
    final time = now == null
        ? formatTime(c.startedAt)
        : '${dayLabel(c.startedAt, now)} · ${formatTime(c.startedAt)}';
    return c.duration.inSeconds < 60 ? time : '$time · ${formatDuration(c.duration)}';
  }

  static String _semanticLabel(ConversationCard c, String title, String meta) {
    return [
      if (c.isOpen) 'Live conversation' else if (c.isProcessing) 'Processing',
      title,
      meta,
      if (c.summary != null) c.summary!,
      if (c.people.isNotEmpty) 'With ${c.people.join(', ')}',
      if (c.taskCount > 0) c.taskCount == 1 ? '1 task' : '${c.taskCount} tasks',
      if (c.photoCount > 0) c.photoCount == 1 ? '1 photo' : '${c.photoCount} photos',
    ].join('. ');
  }
}

/// The conversation title, or a stand-in while it has none.
String conversationTitle(ConversationCard c) {
  final title = c.title;
  if (title != null) return title;
  if (c.isOpen) return 'Conversation in progress';
  if (c.isProcessing) return 'New conversation';
  return 'Untitled conversation';
}

TextStyle? _metaStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 13);

/// The topic emoji in a soft circle, or a neutral icon without one.
final class ConversationEmoji extends StatelessWidget {
  const ConversationEmoji({required this.emoji, this.size = 40, super.key});

  final String? emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: palette.surface2, shape: BoxShape.circle),
        child: emoji == null
            ? Icon(Icons.forum_outlined, size: size * 0.5, color: palette.text2)
            : Text(emoji!, style: TextStyle(fontSize: size * 0.5, height: 1)),
      ),
    );
  }
}

final class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.label, required this.color, this.dot = false});

  final String label;
  final Color color;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot) ...[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
        ],
        Text(
          label,
          style: _metaStyle(context)?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

final class _IconText extends StatelessWidget {
  const _IconText({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final style = _metaStyle(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: style?.color),
        const SizedBox(width: 3),
        Flexible(
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
        ),
      ],
    );
  }
}
