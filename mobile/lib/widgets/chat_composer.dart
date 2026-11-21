import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// What the + in the question box adds.
enum ComposerAddition { camera, photos, files, apps }

/// The question box, a glass capsule over the chat: + (camera, photos, files, apps)
/// on the left, the text, and the microphone on the right, which becomes Send once
/// there is something to send.
final class ChatComposer extends StatelessWidget {
  const ChatComposer({
    required this.controller,
    required this.sending,
    required this.onChanged,
    required this.onSend,
    this.onCamera,
    this.onPhotos,
    this.onDocument,
    this.onApps,
    this.onDictate,
    this.enabled = true,
    this.hintText = 'Ask about your day',
    this.focusNode,
    super.key,
  });

  final TextEditingController controller;
  final bool sending;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;

  /// The phone's camera; the text typed, if any, is the question about the photo.
  final VoidCallback? onCamera;

  /// A photo from the phone's library, asked about like the camera's.
  final VoidCallback? onPhotos;

  /// A document from the phone for Echo to read (Memory → Documents).
  final VoidCallback? onDocument;

  /// The apps Echo can act in, to connect one.
  final VoidCallback? onApps;

  /// Starts dictating the question. No microphone without it.
  final VoidCallback? onDictate;
  final bool enabled;

  /// "Ask about this photo" after "Ask more" under one.
  final String hintText;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final canSend = enabled && !sending && controller.text.trim().isNotEmpty;
    final ready = enabled && !sending;
    final additions = {
      ComposerAddition.camera: onCamera,
      ComposerAddition.photos: onPhotos,
      ComposerAddition.files: onDocument,
      ComposerAddition.apps: onApps,
    }..removeWhere((_, action) => action == null);

    return Padding(
      key: const Key('chat-composer'),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: BoxDecoration(
              color: palette.surface.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: palette.border, width: 0.5),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (additions.isNotEmpty)
                  _AddMenu(
                    enabled: ready,
                    onSelected: (addition) => additions[addition]?.call(),
                    additions: additions.keys.toList(),
                  )
                else
                  const SizedBox(width: 12),
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
                      filled: false,
                      hintText: hintText,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                    ),
                  ),
                ),
                if (canSend || sending)
                  _RoundButton(
                    key: const Key('chat-send'),
                    tooltip: 'Send question',
                    onPressed: canSend ? onSend : null,
                    color: palette.accent,
                    child: sending
                        ? SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: palette.onAccent),
                          )
                        : Icon(CupertinoIcons.arrow_up, size: 20, color: palette.onAccent),
                  )
                else if (onDictate != null)
                  _RoundButton(
                    key: const Key('chat-dictate'),
                    tooltip: 'Dictate',
                    onPressed: ready ? onDictate : null,
                    child: Icon(CupertinoIcons.mic, size: 22, color: palette.text),
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The + and its menu, above the box.
final class _AddMenu extends StatelessWidget {
  const _AddMenu({required this.enabled, required this.onSelected, required this.additions});

  final bool enabled;
  final ValueChanged<ComposerAddition> onSelected;
  final List<ComposerAddition> additions;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return PopupMenuButton<ComposerAddition>(
      key: const Key('chat-add'),
      tooltip: 'Add',
      enabled: enabled,
      onSelected: onSelected,
      position: PopupMenuPosition.over,
      offset: const Offset(0, -12),
      color: palette.surface2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      // No circle of its own: only the press shows
      style: IconButton.styleFrom(
        fixedSize: const Size.square(44),
        backgroundColor: Colors.transparent,
        highlightColor: palette.text.withValues(alpha: 0.12),
      ),
      icon: Icon(CupertinoIcons.add, size: 22, color: palette.text),
      itemBuilder: (context) => [
        for (final addition in additions)
          PopupMenuItem(
            key: Key('chat-${addition.name}'),
            value: addition,
            child: Row(children: [
              Icon(_icon(addition), size: 20, color: palette.accent),
              const SizedBox(width: 12),
              Text(_label(addition)),
            ]),
          ),
      ],
    );
  }

  static IconData _icon(ComposerAddition addition) => switch (addition) {
        ComposerAddition.camera => CupertinoIcons.camera,
        ComposerAddition.photos => CupertinoIcons.photo,
        ComposerAddition.files => CupertinoIcons.doc,
        ComposerAddition.apps => CupertinoIcons.square_grid_2x2,
      };

  static String _label(ComposerAddition addition) => switch (addition) {
        ComposerAddition.camera => 'Camera',
        ComposerAddition.photos => 'Photos',
        ComposerAddition.files => 'Files',
        ComposerAddition.apps => 'Apps',
      };
}

final class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.tooltip,
    required this.onPressed,
    required this.child,
    this.color = Colors.transparent,
    super.key,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 44,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: color,
          disabledBackgroundColor: color.withValues(alpha: color.a * 0.5),
          shape: const CircleBorder(),
        ),
        icon: child,
      ),
    );
  }
}

/// While dictating: what Echo hears, as it hears it, and Done to stop.
final class DictationPanel extends StatelessWidget {
  const DictationPanel({required this.text, this.onStop, super.key});

  final String text;
  final VoidCallback? onStop;

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
          border: Border.all(color: palette.accent, width: 2),
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
                    decoration: BoxDecoration(color: palette.accent, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Listening',
                    style: textTheme.labelMedium?.copyWith(
                      color: palette.onAccentSoft,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (onStop != null)
                    TextButton(
                      key: const Key('dictation-done'),
                      onPressed: onStop,
                      child: const Text('Done'),
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
                'You can change the text before sending it.',
                style: textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
