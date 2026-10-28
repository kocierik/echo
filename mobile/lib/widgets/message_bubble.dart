import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/chat_message.dart';
import '../models/saved.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
import '../utils/photo_follow_ups.dart';
import 'action_card.dart';
import 'panel.dart';
import 'photo_thumbnail.dart';

final class MessageBubble extends StatelessWidget {
  const MessageBubble({
    required this.message,
    this.onConfirmAction,
    this.onCancelAction,
    this.actionBusy = false,
    this.onOpenConversation,
    this.loadPhoto,
    this.onTranslate,
    this.onAskMore,
    this.onRemind,
    this.onOpenSaved,
    this.now,
    super.key,
  });

  final ChatMessage message;

  /// Loads the photo an answer comes with (no photo is shown without it).
  final PhotoSourceLoader? loadPhoto;

  /// Opens the conversation a source comes from.
  final ValueChanged<String>? onOpenConversation;
  final VoidCallback? onConfirmAction;
  final VoidCallback? onCancelAction;
  final bool actionBusy;

  /// The quick follow-ups under a photo's answer: none without them.
  final VoidCallback? onTranslate;
  final VoidCallback? onAskMore;

  /// "Remind me…": only when the photo shows a date still to come.
  final ValueChanged<DateTime>? onRemind;

  /// Opens a thing the answer saved; no chip without it.
  final ValueChanged<SavedChip>? onOpenSaved;

  /// For the reminder chip's label (tests); now by default.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: message.isUser ? 'You asked' : 'Echo answered',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: message.isUser
            ? _question(context)
            : message.photoId != null && loadPhoto != null
                ? _photoAnswer(context)
                : _answer(context),
      ),
    );
  }

  /// The question: ink on the right, like a message sent.
  Widget _question(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (message.byVoice)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mic_none_rounded, size: 13, color: palette.text2),
                const SizedBox(width: 4),
                Text(
                  message.timestamp == null
                      ? 'By voice'
                      : 'By voice · ${formatTime(message.timestamp!)}',
                  style: textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: palette.text,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
              child: Text(
                message.text,
                style: textTheme.bodyMedium?.copyWith(color: palette.background, height: 1.4),
              ),
            ),
          ),
        ),
        if (message.failed)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Send failed',
              style: textTheme.labelMedium?.copyWith(color: palette.red),
            ),
          ),
      ],
    );
  }

  /// A photo's answer: the photo large (a tap opens it full screen), what Echo saw,
  /// then quick follow-ups about the same photo.
  Widget _photoAnswer(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final at = message.timestamp;
    final when = message.when;
    final now = this.now ?? DateTime.now();
    final remind = when != null && when.isAfter(now) ? onRemind : null;
    final chips = [
      if (onTranslate != null)
        _FollowUp(key: const Key('photo-translate'), label: 'Translate it', onTap: onTranslate!),
      if (remind != null)
        _FollowUp(
          key: const Key('photo-remind'),
          label: reminderChipLabel(when!, now),
          onTap: () => remind(when),
        ),
      if (onAskMore != null)
        _FollowUp(key: const Key('photo-ask-more'), label: 'Ask more', onTap: onAskMore!),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: palette.surface,
          borderRadius: BorderRadius.circular(AppTheme.panelRadius),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PhotoThumbnail(
                photoId: message.photoId!,
                loadSource: loadPhoto!,
                height: 260,
                padding: EdgeInsets.zero,
                caption: at == null ? "Echo's camera" : "Echo's camera · ${formatTime(at)}",
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: MarkdownBody(
                  data: message.text,
                  selectable: true,
                  onTapLink: (_, href, __) => _launch(href),
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                    p: textTheme.bodyMedium?.copyWith(height: 1.45),
                  ),
                ),
              ),
              ..._savedChips(),
            ],
          ),
        ),
        if (chips.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(spacing: 8, runSpacing: 8, children: chips),
          ),
      ],
    );
  }

  /// The answer: a panel with what Echo did and its sources.
  Widget _answer(BuildContext context) {
    final palette = EchoPalette.of(context);
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final routine = message.routineId != null;
    return Panel(
      // A routine's answer: Echo did it on its own, at the time asked
      color: routine ? palette.accentSoft : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (routine)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                [
                  'ROUTINE',
                  if (message.routineSchedule case final schedule?) schedule.toUpperCase(),
                ].join(' · '),
                style: textTheme.labelSmall?.copyWith(
                  color: palette.onAccentSoft,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          MarkdownBody(
            data: message.text,
            selectable: true,
            onTapLink: (_, href, __) => _launch(href),
            styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
              p: textTheme.bodyMedium?.copyWith(height: 1.5),
              h1: textTheme.titleLarge,
              h2: textTheme.titleMedium,
              h3: textTheme.titleSmall,
              code: TextStyle(
                color: palette.accent,
                backgroundColor: palette.surface2,
                fontFamily: 'monospace',
              ),
              codeblockDecoration: BoxDecoration(
                color: palette.surface2,
                borderRadius: BorderRadius.circular(AppTheme.tileRadius),
              ),
              blockquoteDecoration: BoxDecoration(
                border: Border(left: BorderSide(color: palette.accent, width: 3)),
              ),
            ),
          ),
          if (message.photoId != null && loadPhoto != null)
            PhotoThumbnail(photoId: message.photoId!, loadSource: loadPhoto!),
          ..._savedChips(),
          if (message.pendingAction != null)
            ActionCard(
              action: message.pendingAction!,
              busy: actionBusy,
              onConfirm: onConfirmAction ?? () {},
              onCancel: onCancelAction ?? () {},
            ),
          if (message.sources.isNotEmpty)
            _Sources(sources: message.sources, onOpenConversation: onOpenConversation),
          if (message.failed)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Send failed',
                style: textTheme.labelMedium?.copyWith(color: palette.red),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _savedChips() {
    final open = onOpenSaved;
    if (open == null || message.saved.isEmpty) return const [];
    return [
      for (final chip in message.saved)
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
          child: _SavedChip(chip: chip, onTap: () => open(chip)),
        ),
    ];
  }

  Future<void> _launch(String? rawUrl) async {
    final uri = rawUrl == null ? null : Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// What an answer saved: "Your car · Saved", where it is or its list; a tap opens it.
final class _SavedChip extends StatelessWidget {
  const _SavedChip({required this.chip, required this.onTap});

  final SavedChip chip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: palette.accentSoft,
      borderRadius: BorderRadius.circular(AppTheme.tileRadius),
      child: InkWell(
        key: Key('saved-chip-${chip.id}'),
        borderRadius: BorderRadius.circular(AppTheme.tileRadius),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.bookmark_rounded, size: 18, color: palette.onAccentSoft),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${chip.title} · Saved',
                        style: textTheme.labelLarge?.copyWith(color: palette.onAccentSoft),
                      ),
                      Text(
                        chip.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(color: palette.onAccentSoft),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: palette.onAccentSoft),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A quick follow-up under a photo: a rounded button.
final class _FollowUp extends StatelessWidget {
  const _FollowUp({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Material(
      color: palette.surface,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(color: palette.text),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where the answer comes from: the first two passages as tiles (a tap opens
/// the conversation or the page), the others on request.
final class _Sources extends StatefulWidget {
  const _Sources({required this.sources, this.onOpenConversation});

  static const shown = 2;

  final List<ChatSource> sources;
  final ValueChanged<String>? onOpenConversation;

  @override
  State<_Sources> createState() => _SourcesState();
}

final class _SourcesState extends State<_Sources> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final sources = widget.sources;
    final hidden = sources.length - _Sources.shown;
    final visible = _all || hidden <= 0 ? sources : sources.take(_Sources.shown);
    return Column(
      key: const Key('chat-sources'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final source in visible)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: _SourceTile(source: source, onOpenConversation: widget.onOpenConversation),
          ),
        if (hidden > 0 && !_all)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('chat-sources-more'),
              onPressed: () => setState(() => _all = true),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              child: Text(hidden == 1 ? '1 more source' : '$hidden more sources'),
            ),
          ),
      ],
    );
  }
}

final class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.source, this.onOpenConversation});

  final ChatSource source;
  final ValueChanged<String>? onOpenConversation;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final conversationId = source.conversationId;
    final url = source.url;
    final VoidCallback? onTap = url != null
        ? () => launchUrl(url, mode: LaunchMode.externalApplication)
        : conversationId != null && onOpenConversation != null
            ? () => onOpenConversation!(conversationId)
            : null;
    final radius = BorderRadius.circular(AppTheme.tileRadius);
    return Semantics(
      button: onTap != null,
      hint: url != null
          ? 'Opens the page'
          : onTap != null
              ? 'Opens the conversation'
              : null,
      child: Material(
        color: palette.tint,
        borderRadius: radius,
        child: InkWell(
          key: Key('chat-source-${source.chunkId ?? conversationId ?? source.label}'),
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    url != null ? Icons.link_rounded : Icons.graphic_eq_rounded,
                    size: 20,
                    color: palette.accent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        source.label,
                        style: textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (source.text.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          source.text,
                          maxLines: onTap == null ? null : 3,
                          overflow: onTap == null ? null : TextOverflow.ellipsis,
                          style: textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                if (url != null)
                  Icon(Icons.open_in_new_rounded, size: 16, color: palette.text2)
                else if (onTap != null)
                  Icon(Icons.chevron_right_rounded, size: 18, color: palette.text2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
