import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/chat_message.dart';
import '../theme/app_theme.dart';

final class MessageBubble extends StatelessWidget {
  const MessageBubble({
    required this.message,
    this.onFeedback,
    super.key,
  });

  final ChatMessage message;
  final ValueChanged<String>? onFeedback;

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

/*
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/chat_message.dart';
import '../theme/app_theme.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final Function(String)? onFeedback;

  const MessageBubble({super.key, required this.message, this.onFeedback});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        child: Column(
          crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isUser ? AppColors.accent : AppColors.bgElevated,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: Radius.circular(isUser ? 20 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 20),
                ),
                border: isUser ? null : Border.all(color: AppColors.border),
              ),
              child: isUser
                  ? Text(
                      message.text,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.45,
                        color: Colors.white,
                      ),
                    )
                  : MarkdownBody(
                      data: message.text,
                      selectable: true,
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(fontSize: 15, height: 1.45, color: AppColors.foreground),
                        strong: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.foreground),
                        em: const TextStyle(fontSize: 15, fontStyle: FontStyle.italic, color: AppColors.foreground),
                        h1: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.foreground),
                        h2: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.foreground),
                        h3: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.foreground),
                        listBullet: const TextStyle(fontSize: 15, color: AppColors.foreground),
                        code: const TextStyle(fontSize: 13, color: AppColors.accent, backgroundColor: AppColors.surface),
                        codeblockDecoration: const BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                        ),
                        blockquoteDecoration: const BoxDecoration(
                          border: Border(left: BorderSide(color: AppColors.accent, width: 3)),
                        ),
                        blockquotePadding: const EdgeInsets.only(left: 12),
                        listIndent: 16,
                      ),
                    ),
            ),
            // Feedback row
            if (!isUser && onFeedback != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _FeedbackButton(
                      icon: Icons.thumb_up_outlined,
                      active: message.feedback == 'positive',
                      activeColor: AppColors.success,
                      onTap: () => onFeedback!('positive'),
                    ),
                    const SizedBox(width: 6),
                    _FeedbackButton(
                      icon: Icons.thumb_down_outlined,
                      active: message.feedback == 'negative',
                      activeColor: AppColors.error,
                      onTap: () => onFeedback!('negative'),
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

class _FeedbackButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;

  const _FeedbackButton({
    required this.icon,
    required this.active,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: active ? activeColor.withValues(alpha: 0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? activeColor.withValues(alpha: 0.4) : AppColors.border),
        ),
        child: Icon(icon, size: 14, color: active ? activeColor : AppColors.foregroundMuted),
      ),
    );
  }
}
*/
