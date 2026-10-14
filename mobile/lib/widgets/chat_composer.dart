import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

final class ChatComposer extends StatelessWidget {
  const ChatComposer({
    required this.controller,
    required this.sending,
    required this.listening,
    required this.onChanged,
    required this.onSend,
    required this.onVoice,
    this.onCamera,
    this.enabled = true,
    super.key,
  });

  final TextEditingController controller;
  final bool sending;
  final bool listening;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final VoidCallback onVoice;

  /// The wearable takes a photo; the text typed, if any, is the question about it.
  /// No button without it.
  final VoidCallback? onCamera;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final canSend = enabled && !sending && controller.text.trim().isNotEmpty;

    return Container(
      key: const Key('chat-composer'),
      constraints: const BoxConstraints(minHeight: 54),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      color: palette.background,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox.square(
            dimension: 44,
            child: IconButton(
              key: const Key('chat-mic'),
              onPressed: enabled ? onVoice : null,
              tooltip: listening ? 'Stop listening' : 'Use voice input',
              icon: Icon(
                listening ? Icons.stop_rounded : Icons.mic_none_rounded,
                color: listening ? palette.red : palette.text2,
              ),
            ),
          ),
          if (onCamera != null)
            SizedBox.square(
              dimension: 44,
              child: IconButton(
                key: const Key('chat-camera'),
                onPressed: enabled && !sending ? onCamera : null,
                tooltip: 'Ask Echo about what you see',
                icon: Icon(Icons.photo_camera_outlined, color: palette.text2),
              ),
            ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              key: const Key('chat-input'),
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onChanged: onChanged,
              onSubmitted: (_) {
                if (canSend) onSend();
              },
              decoration: const InputDecoration(
                hintText: 'Ask your memory',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox.square(
            dimension: 44,
            child: IconButton.filled(
              key: const Key('chat-send'),
              onPressed: canSend ? onSend : null,
              tooltip: 'Send question',
              style: IconButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: sending
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_upward_rounded),
            ),
          ),
        ],
      ),
    );
  }
}