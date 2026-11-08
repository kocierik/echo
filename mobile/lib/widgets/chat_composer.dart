import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The question box: the text, a document to add, the wearable's camera, and Send once
/// there is something to send. Dictation is the navigation's Ask button, held.
final class ChatComposer extends StatelessWidget {
  const ChatComposer({
    required this.controller,
    required this.sending,
    required this.onChanged,
    required this.onSend,
    this.onCamera,
    this.onDocument,
    this.enabled = true,
    this.hintText = 'Ask about your day',
    this.focusNode,
    super.key,
  });

  final TextEditingController controller;
  final bool sending;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;

  /// The wearable takes a photo; the text typed, if any, is the question about it.
  /// No button without it.
  final VoidCallback? onCamera;

  /// A document from the phone for Echo to read (Memory → Documents). No button without it.
  final VoidCallback? onDocument;
  final bool enabled;

  /// "Ask about this photo" after "Ask more" under one.
  final String hintText;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final canSend = enabled && !sending && controller.text.trim().isNotEmpty;

    return Padding(
      key: const Key('chat-composer'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              key: const Key('chat-input'),
              controller: controller,
              focusNode: focusNode,
              enabled: enabled,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onChanged: onChanged,
              onSubmitted: (_) {
                if (canSend) onSend();
              },
              decoration: InputDecoration(
                hintText: hintText,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(25)),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (onDocument != null) ...[
            const SizedBox(width: 8),
            _RoundButton(
              key: const Key('chat-document'),
              tooltip: 'Add a document',
              onPressed: enabled && !sending ? onDocument : null,
              color: palette.surface,
              child: Icon(Icons.attach_file_rounded, size: 22, color: palette.text),
            ),
          ],
          if (onCamera != null) ...[
            const SizedBox(width: 8),
            _RoundButton(
              key: const Key('chat-camera'),
              tooltip: 'Ask Echo about what you see',
              onPressed: enabled && !sending ? onCamera : null,
              color: palette.surface,
              child: Icon(Icons.photo_camera_outlined, size: 22, color: palette.text),
            ),
          ],
          if (canSend || sending) ...[
            const SizedBox(width: 8),
            _RoundButton(
              key: const Key('chat-send'),
              tooltip: 'Send question',
              onPressed: canSend ? onSend : null,
              color: palette.text,
              child: sending
                  ? SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: palette.background),
                    )
                  : Icon(Icons.arrow_upward_rounded, color: palette.background),
            ),
          ],
        ],
      ),
    );
  }
}

final class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.tooltip,
    required this.onPressed,
    required this.color,
    required this.child,
    super.key,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 50,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        style: IconButton.styleFrom(
          backgroundColor: color,
          disabledBackgroundColor: color.withValues(alpha: 0.5),
          shape: const CircleBorder(),
        ),
        icon: child,
      ),
    );
  }
}

/// While the Ask button is held: what Echo hears, as it hears it.
final class DictationPanel extends StatelessWidget {
  const DictationPanel({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        key: const Key('dictation-panel'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(AppTheme.panelRadius),
          border: Border.all(color: palette.live, width: 2),
        ),
        child: Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(color: palette.live, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Listening',
                    style: textTheme.labelMedium?.copyWith(
                      color: palette.liveText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                text.isEmpty ? 'Say your question…' : text,
                style: textTheme.bodyLarge?.copyWith(
                  fontSize: 18,
                  height: 1.4,
                  color: text.isEmpty ? palette.text2 : null,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Let go to stop. You can change the text before sending it.',
                style: textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
