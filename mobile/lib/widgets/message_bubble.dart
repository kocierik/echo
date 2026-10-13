import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/chat_message.dart';
import '../theme/app_theme.dart';
import 'action_card.dart';

final class MessageBubble extends StatelessWidget {
  const MessageBubble({
    required this.message,
    this.onFeedback,
    this.onConfirmAction,
    this.onCancelAction,
    this.actionBusy = false,
    super.key,
  });

  final ChatMessage message;
  final ValueChanged<String>? onFeedback;
  final VoidCallback? onConfirmAction;
  final VoidCallback? onCancelAction;
  final bool actionBusy;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final role = message.isUser ? 'You' : 'Echo';
    return Semantics(
      container: true,
      label: '$role message',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              role,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: message.isUser ? palette.blue : palette.green,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 5),
            if (message.isUser)
              Text(
                message.text,
                style: Theme.of(context).textTheme.bodyLarge,
              )
            else
              MarkdownBody(
                data: message.text,
                selectable: true,
                onTapLink: (_, href, __) => _launch(href),
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                  p: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.45),
                  h1: Theme.of(context).textTheme.titleLarge,
                  h2: Theme.of(context).textTheme.titleMedium,
                  h3: Theme.of(context).textTheme.titleSmall,
                  code: TextStyle(
                    color: palette.blue,
                    backgroundColor: palette.surface2,
                    fontFamily: 'monospace',
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: palette.surface2,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  blockquoteDecoration: BoxDecoration(
                    border: Border(left: BorderSide(color: palette.blue, width: 3)),
                  ),
                ),
              ),
            if (!message.isUser && message.pendingAction != null)
              ActionCard(
                action: message.pendingAction!,
                busy: actionBusy,
                onConfirm: onConfirmAction ?? () {},
                onCancel: onCancelAction ?? () {},
              ),
            if (message.failed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Send failed',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: palette.red,
                      ),
                ),
              ),
            if (!message.isUser && message.sources.isNotEmpty)
              _Sources(sources: message.sources),
            if (!message.isUser && onFeedback != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    _FeedbackButton(
                      tooltip: 'Helpful',
                      icon: Icons.thumb_up_outlined,
                      active: message.feedback == 'positive',
                      activeColor: palette.green,
                      onPressed: () => onFeedback!('positive'),
                    ),
                    _FeedbackButton(
                      tooltip: 'Not helpful',
                      icon: Icons.thumb_down_outlined,
                      active: message.feedback == 'negative',
                      activeColor: palette.red,
                      onPressed: () => onFeedback!('negative'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _launch(String? rawUrl) async {
    final uri = rawUrl == null ? null : Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

final class _Sources extends StatelessWidget {
  const _Sources({required this.sources});

  final List<ChatSource> sources;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const Key('chat-sources'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        minTileHeight: 44,
        title: Text(
          'Sources (${sources.length})',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: palette.text2,
              ),
        ),
        children: sources.map((source) {
          final content = Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        source.label,
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: palette.blue,
                            ),
                      ),
                    ),
                    if (source.url != null)
                      const Icon(Icons.open_in_new_rounded, size: 16),
                  ],
                ),
                if (source.text.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(source.text),
                ],
              ],
            ),
          );
          if (source.url == null) return content;
          return InkWell(
            onTap: () => launchUrl(
              source.url!,
              mode: LaunchMode.externalApplication,
            ),
            child: content,
          );
        }).toList(),
      ),
    );
  }
}

final class _FeedbackButton extends StatelessWidget {
  const _FeedbackButton({
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.activeColor,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 44,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        iconSize: 18,
        color: active ? activeColor : EchoPalette.of(context).text2,
        icon: Icon(active ? _filledIcon(icon) : icon),
      ),
    );
  }

  IconData _filledIcon(IconData icon) {
    if (icon == Icons.thumb_up_outlined) return Icons.thumb_up_rounded;
    return Icons.thumb_down_rounded;
  }
}
