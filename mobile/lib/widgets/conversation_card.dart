import 'package:flutter/cupertino.dart';
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
                            icon: CupertinoIcons.person,
                            text: c.people.join(', '),
                          ),
                        if (c.place?.label case final place?)
                          _IconText(icon: CupertinoIcons.location, text: place),
                        if (c.taskCount > 0)
                          _IconText(
                            icon: CupertinoIcons.checkmark_circle,
                            text: c.taskCount == 1 ? '1 task' : '${c.taskCount} tasks',
                          ),
                        if (c.photoCount > 0)
                          _IconText(
                            icon: CupertinoIcons.camera,
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
      if (c.place?.label case final place?) 'At $place',
      if (c.taskCount > 0) c.taskCount == 1 ? '1 task' : '${c.taskCount} tasks',
      if (c.photoCount > 0) c.photoCount == 1 ? '1 photo' : '${c.photoCount} photos',
    ].join('. ');
  }
}

/// A conversation inside a day's panel: its time on the left; title, summary
/// and chips (live, people, tasks, photos, length) on the right.
final class ConversationRow extends StatelessWidget {
  const ConversationRow({required this.conversation, required this.onTap, super.key});

  final ConversationCard conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final c = conversation;
    final title = conversationTitle(c);
    final meta = ConversationCardTile._meta(c, null);
    final chips = <Widget>[
      if (c.isOpen)
        _Chip(label: 'Live', color: palette.accentSoft, text: palette.onAccentSoft)
      else if (c.isProcessing)
        _Chip(label: 'Processing', color: palette.surface2, text: palette.amber),
      if (c.people.isNotEmpty)
        _Chip(label: c.people.join(', '), color: palette.surface2, text: palette.text),
      if (c.place?.label case final place?)
        _Chip(label: place, color: palette.surface2, text: palette.text),
      if (c.taskCount > 0)
        _Chip(
          label: c.taskCount == 1 ? '1 task' : '${c.taskCount} tasks',
          color: palette.accentSoft,
          text: palette.onAccentSoft,
        ),
      if (c.photoCount > 0)
        _Chip(
          label: c.photoCount == 1 ? '1 photo' : '${c.photoCount} photos',
          color: palette.surface2,
          text: palette.text,
        ),
      if (c.duration.inSeconds >= 60)
        _Chip(label: formatDuration(c.duration), color: palette.surface2, text: palette.text),
    ];
    return Semantics(
      button: true,
      label: ConversationCardTile._semanticLabel(c, title, meta),
      excludeSemantics: true,
      child: InkWell(
        key: Key('conversation-${c.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 46,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    formatTime(c.startedAt),
                    style: textTheme.labelMedium?.copyWith(
                      color: palette.text2,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
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
                    if (c.summary case final summary?) ...[
                      const SizedBox(height: 3),
                      Text(
                        summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(height: 1.4),
                      ),
                    ],
                    if (chips.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(spacing: 6, runSpacing: 6, children: chips),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color, required this.text});

  final String label;
  final Color color;
  final Color text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: text,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
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
            ? Icon(CupertinoIcons.chat_bubble_2, size: size * 0.5, color: palette.text2)
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
