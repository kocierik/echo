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
                        code: TextStyle(fontSize: 13, color: AppColors.accent, backgroundColor: AppColors.surface),
                        codeblockDecoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        blockquoteDecoration: BoxDecoration(
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
          color: active ? activeColor.withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? activeColor.withOpacity(0.4) : AppColors.border),
        ),
        child: Icon(icon, size: 14, color: active ? activeColor : AppColors.foregroundMuted),
      ),
    );
  }
}
