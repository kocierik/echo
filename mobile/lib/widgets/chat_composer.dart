import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

final class ChatComposer extends StatelessWidget {
  const ChatComposer({
    required this.controller,
    required this.sending,
    required this.listening,
    required this.onChanged,
    required this.onSend,
    required this.onVoiceStart,
    required this.onVoiceEnd,
    this.onCamera,
    this.enabled = true,
    super.key,
  });

  final TextEditingController controller;
  final bool sending;
  final bool listening;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;

  /// Dictation runs while the mic is held: it starts on the press...
  final VoidCallback onVoiceStart;

  /// ...and ends on the release, with how long it was held (a tap is too short).
  final ValueChanged<Duration> onVoiceEnd;

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
          HoldToTalkButton(
            enabled: enabled && !sending,
            listening: listening,
            onStart: onVoiceStart,
            onEnd: onVoiceEnd,
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
              decoration: InputDecoration(
                hintText: listening ? 'Listening… release to stop' : 'Ask your memory',
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
/// The mic: dictation lasts as long as the button is held.
final class HoldToTalkButton extends StatefulWidget {
  const HoldToTalkButton({
    required this.enabled,
    required this.listening,
    required this.onStart,
    required this.onEnd,
    super.key,
  });

  final bool enabled;
  final bool listening;
  final VoidCallback onStart;
  final ValueChanged<Duration> onEnd;

  @override
  State<HoldToTalkButton> createState() => _HoldToTalkButtonState();
}

final class _HoldToTalkButtonState extends State<HoldToTalkButton> {
  DateTime? _pressedAt;

  void _down(PointerDownEvent _) {
    if (!widget.enabled || _pressedAt != null) return;
    setState(() => _pressedAt = clock.now());
    widget.onStart();
  }

  void _up(PointerEvent _) {
    final pressedAt = _pressedAt;
    if (pressedAt == null) return;
    setState(() => _pressedAt = null);
    widget.onEnd(clock.now().difference(pressedAt));
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final active = widget.listening || _pressedAt != null;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: active ? 'Listening. Release to stop' : 'Hold to talk',
      child: Listener(
        key: const Key('chat-mic'),
        onPointerDown: _down,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: Tooltip(
          message: 'Hold to talk',
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? palette.red.withValues(alpha: 0.14) : Colors.transparent,
            ),
            child: Icon(
              active ? Icons.mic_rounded : Icons.mic_none_rounded,
              color: !widget.enabled
                  ? palette.text2.withValues(alpha: 0.4)
                  : active
                      ? palette.red
                      : palette.text2,
            ),
          ),
        ),
      ),
    );
  }
}
