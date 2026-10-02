import 'package:flutter/material.dart';

import '../models/segment.dart';
import '../models/transcript_group.dart';
import '../theme/app_theme.dart';

final class TranscriptGroupSection extends StatelessWidget {
  const TranscriptGroupSection({
    super.key,
    required this.group,
    required this.onOpen,
  });

  final TranscriptGroup group;
  final ValueChanged<RecentSegment> onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
          child: Text(
            group.label.toUpperCase(),
            style: TextStyle(
              color: palette.text2,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        ),
        for (var index = 0; index < group.items.length; index++) ...[
          _TranscriptTimelineRow(
            segment: group.items[index],
            onOpen: onOpen,
          ),
          if (index != group.items.length - 1)
            Divider(
              height: 1,
              indent: 72,
              endIndent: 20,
              color: palette.border,
            ),
        ],
      ],
    );
  }
}

final class _TranscriptTimelineRow extends StatelessWidget {
  const _TranscriptTimelineRow({
    required this.segment,
    required this.onOpen,
  });

  final RecentSegment segment;
  final ValueChanged<RecentSegment> onOpen;

  bool get _canOpen {
    final conversationId = segment.conversationId;
    return conversationId != null && conversationId.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    final text = _displayText(segment);
    final status = _statusText(segment);
    final speaker = _speakerText(segment.speaker);
    final semanticsParts = <String>[
      _formatTime(segment.recordedAt),
      text,
      status,
      if (speaker != null) speaker,
    ];

    return Semantics(
      container: true,
      button: _canOpen,
      onTap: _canOpen ? () => onOpen(segment) : null,
      label: semanticsParts.join(', '),
      child: Padding(
        key: Key('transcript-row-${segment.id}'),
        padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 40,
              child: Text(
                _formatTime(segment.recordedAt),
                style: TextStyle(fontSize: 11, color: palette.text2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: segment.text == null ? palette.text2 : palette.text,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _Status(segment: segment),
                      if (speaker != null)
                        Text(
                          speaker,
                          style: TextStyle(fontSize: 11, color: palette.text2),
                        ),
                      Text(
                        '${(segment.durationMs / 1000).toStringAsFixed(1)}s',
                        style: TextStyle(fontSize: 11, color: palette.text2),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_canOpen)
              SizedBox.square(
                dimension: 44,
                child: IconButton(
                  key: Key('open-transcript-${segment.id}'),
                  tooltip: 'Open transcript',
                  onPressed: () => onOpen(segment),
                  icon: Icon(
                    Icons.chevron_right_rounded,
                    color: palette.text2,
                  ),
                ),
              )
            else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

final class _Status extends StatelessWidget {
  const _Status({required this.segment});

  final RecentSegment segment;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    if (segment.isPending) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 11,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: palette.blue,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            'Transcribing',
            style: TextStyle(fontSize: 11, color: palette.blue),
          ),
        ],
      );
    }
    if (segment.isFailed) {
      return Text(
        'Failed',
        style: TextStyle(fontSize: 11, color: palette.red),
      );
    }
    return Text(
      'Completed',
      style: TextStyle(fontSize: 11, color: palette.green),
    );
  }
}

String _displayText(RecentSegment segment) {
  final text = segment.text?.trim();
  if (text == null || text.isEmpty) {
    return segment.isFailed ? 'Transcription failed' : 'Transcribing...';
  }
  return text.replaceFirst(
    RegExp(r'^\[(Tu|Altri|You|Other)\]\s*', caseSensitive: false),
    '',
  );
}

String _statusText(RecentSegment segment) {
  if (segment.isPending) return 'Transcribing';
  if (segment.isFailed) return 'Failed';
  return 'Completed';
}

String? _speakerText(String? speaker) {
  return switch (speaker?.toLowerCase()) {
    'self' => 'You',
    'other' => 'Other',
    _ => null,
  };
}

String _formatTime(DateTime value) {
  final local = value.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}