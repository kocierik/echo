import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/chat_message.dart';
import '../theme/app_theme.dart';
import '../utils/formatting.dart';
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

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: message.isUser ? 'You asked' : 'Echo answered',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: message.isUser ? _question(context) : _answer(context),
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
                'ROUTINE',
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

  Future<void> _launch(String? rawUrl) async {
    final uri = rawUrl == null ? null : Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
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
