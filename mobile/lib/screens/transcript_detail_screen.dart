import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/segment.dart';
import '../services/api/api_exception.dart';
import '../services/api/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/panel.dart';

class TranscriptDetailScreen extends StatefulWidget {
  const TranscriptDetailScreen({
    super.key,
    required this.segment,
    this.api,
  });

  final RecentSegment segment;
  final TranscriptMemoryApi? api;

  @override
  State<TranscriptDetailScreen> createState() =>
      _TranscriptDetailScreenState();
}

class _TranscriptDetailScreenState extends State<TranscriptDetailScreen> {
  late final TextEditingController _textController;
  late final TranscriptMemoryApi _api;
  ApiService? _ownedApi;

  late String _baselineText;
  late String _baselineSpeaker;
  late String _speaker;
  TranscriptionCorrectionResult? _correctionResult;
  _VisibleError? _saveError;
  _VisibleError? _deleteError;
  bool _submitting = false;
  bool _deleting = false;
  int _operationGeneration = 0;

  bool get _editable {
    final text = widget.segment.text;
    final conversationId = widget.segment.conversationId;
    return widget.segment.isCompleted &&
        text != null &&
        text.trim().isNotEmpty &&
        conversationId != null &&
        conversationId.isNotEmpty;
  }

  bool get _busy => _submitting || _deleting;
  bool get _canDelete {
    final conversationId = widget.segment.conversationId;
    return conversationId != null && conversationId.isNotEmpty;
  }
  bool get _textIsEmpty => _textController.text.trim().isEmpty;
  bool get _hasChanges =>
      _textController.text.trim() != _baselineText ||
      _speaker != _baselineSpeaker;
  bool get _canSave => _editable && !_busy && !_textIsEmpty && _hasChanges;

  @override
  void initState() {
    super.initState();
    final injectedApi = widget.api;
    if (injectedApi == null) {
      final ownedApi = ApiService();
      _ownedApi = ownedApi;
      _api = ownedApi;
    } else {
      _api = injectedApi;
    }

    _baselineText = _stripDisplayPrefix(widget.segment.text ?? '').trim();
    _baselineSpeaker = _normalizeSpeaker(widget.segment.speaker);
    _speaker = _baselineSpeaker;
    _textController = TextEditingController(text: _baselineText)
      ..addListener(_handleTextChanged);
  }

  @override
  void dispose() {
    _operationGeneration++;
    _textController
      ..removeListener(_handleTextChanged)
      ..dispose();
    _ownedApi?.dispose();
    super.dispose();
  }

  void _handleTextChanged() {
    if (!mounted) return;
    setState(() {
      _saveError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Scaffold(
      key: const Key('transcript-detail-screen'),
      backgroundColor: palette.background,
      appBar: AppBar(title: const Text('Transcript')),
      body: SafeArea(
        child: _editable ? _buildEditor() : _buildReadOnly(),
      ),
    );
  }

  Widget _buildEditor() {
    final palette = EchoPalette.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        // The text and who said it, in one panel
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            Text(
              'TRANSCRIPT',
              style: TextStyle(
                color: palette.text2,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('transcript-text-field'),
              controller: _textController,
              enabled: !_busy,
              minLines: 5,
              maxLines: null,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Transcript text',
                filled: true,
                fillColor: palette.surface2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.tileRadius),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            if (_textIsEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Transcript text is required.',
                key: const Key('transcript-text-error'),
                style: TextStyle(color: palette.red, fontSize: 12),
              ),
            ],
            const SizedBox(height: 24),
            Text(
              'SPEAKER',
              style: TextStyle(
                color: palette.text2,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Semantics(
              label: 'Speaker',
              child: SegmentedButton<String>(
                key: const Key('speaker-selector'),
                segments: const [
                  ButtonSegment(
                    value: 'self',
                    label: Text('You', key: Key('speaker-self')),
                  ),
                  ButtonSegment(
                    value: 'other',
                    label: Text('Other', key: Key('speaker-other')),
                  ),
                  ButtonSegment(
                    value: 'unknown',
                    label: Text('Unknown', key: Key('speaker-unknown')),
                  ),
                ],
                selected: {_speaker},
                onSelectionChanged: _busy
                    ? null
                    : (selection) {
                        setState(() {
                          _speaker = selection.single;
                          _saveError = null;
                        });
                      },
              ),
            ),
            ],
          ),
        ),
        if (_correctionResult != null) ...[
          const SizedBox(height: 16),
          _CorrectionStatus(result: _correctionResult!),
        ],
        if (_saveError != null) ...[
          const SizedBox(height: 16),
          _ErrorPanel(
            key: const Key('save-transcript-error'),
            error: _saveError!,
            retryKey: const Key('retry-save-transcript'),
            retryLabel: 'Retry save',
            onRetry: _busy ? null : _save,
          ),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          key: const Key('save-transcript'),
          onPressed: _canSave ? _save : null,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          icon: _submitting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(CupertinoIcons.tray_arrow_down),
          label: Text(_submitting ? 'Saving...' : 'Save correction'),
        ),
        const SizedBox(height: 32),
        Divider(color: palette.border),
        const SizedBox(height: 16),
        if (_deleteError != null) ...[
          _ErrorPanel(
            key: const Key('delete-conversation-error'),
            error: _deleteError!,
            retryKey: const Key('retry-delete-conversation'),
            retryLabel: 'Retry delete',
            onRetry: _busy ? null : _deleteConversation,
          ),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          key: const Key('delete-conversation'),
          onPressed: _busy ? null : _confirmDelete,
          style: OutlinedButton.styleFrom(
            foregroundColor: palette.red,
            side: BorderSide(color: palette.red),
            minimumSize: const Size.fromHeight(48),
          ),
          icon: _deleting
              ? const SizedBox.square(
                  key: Key('delete-conversation-progress'),
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(CupertinoIcons.delete),
          label: Text(_deleting ? 'Deleting...' : 'Delete conversation'),
        ),
      ],
    );
  }

  Widget _buildReadOnly() {
    final palette = EchoPalette.of(context);
    final text = _stripDisplayPrefix(widget.segment.text ?? '').trim();
    final message = widget.segment.isFailed
        ? 'Transcription failed'
        : widget.segment.isPending
            ? 'Transcribing...'
            : text.isEmpty
                ? 'No transcript text is available.'
                : text;
    final status = widget.segment.isFailed
        ? 'Failed transcripts are read-only.'
        : widget.segment.isPending
            ? 'This transcript can be edited after processing completes.'
            : 'This transcript is read-only.';

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          message,
          key: const Key('read-only-transcript'),
          style: TextStyle(
            color: palette.text,
            fontSize: 15,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          status,
          style: TextStyle(
            color: palette.text2,
            fontSize: 13,
          ),
        ),
        if (_canDelete) ...[
          const SizedBox(height: 32),
          if (_deleteError != null) ...[
            _ErrorPanel(
              key: const Key('delete-conversation-error'),
              error: _deleteError!,
              retryKey: const Key('retry-delete-conversation'),
              retryLabel: 'Retry delete',
              onRetry: _busy ? null : _deleteConversation,
            ),
            const SizedBox(height: 12),
          ],
          OutlinedButton.icon(
            key: const Key('delete-conversation'),
            onPressed: _busy ? null : _confirmDelete,
            style: OutlinedButton.styleFrom(
              foregroundColor: palette.red,
              side: BorderSide(color: palette.red),
              minimumSize: const Size.fromHeight(48),
            ),
            icon: _deleting
                ? const SizedBox.square(
                    key: Key('delete-conversation-progress'),
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(CupertinoIcons.delete),
            label: Text(
              _deleting ? 'Deleting...' : 'Delete conversation',
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _save() async {
    if (!_canSave) return;
    final text = _textController.text.trim();
    final speaker = _speaker;
    final generation = ++_operationGeneration;
    setState(() {
      _submitting = true;
      _saveError = null;
    });

    try {
      final result = await _api.correctTranscription(
        widget.segment.id,
        text,
        speaker,
      );
      if (!mounted || generation != _operationGeneration) return;

      _textController.value = TextEditingValue(
        text: result.text,
        selection: TextSelection.collapsed(offset: result.text.length),
      );
      setState(() {
        _baselineText = result.text.trim();
        _baselineSpeaker = _normalizeSpeaker(result.speakerLabel);
        _speaker = _baselineSpeaker;
        _correctionResult = result;
        _submitting = false;
      });
    } catch (error) {
      if (!mounted || generation != _operationGeneration) return;
      setState(() {
        _submitting = false;
        _saveError = _VisibleError.from(error);
      });
    }
  }

  Future<void> _confirmDelete() async {
    final palette = EchoPalette.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: const Text(
          'This permanently deletes the conversation and its stored memory.',
        ),
        actions: [
          TextButton(
            key: const Key('cancel-delete-conversation'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-delete-conversation'),
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: palette.red,
              minimumSize: const Size(44, 44),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _deleteConversation();
    }
  }

  Future<void> _deleteConversation() async {
    final conversationId = widget.segment.conversationId;
    if (!_canDelete || conversationId == null || _busy) return;
    final generation = ++_operationGeneration;
    setState(() {
      _deleting = true;
      _deleteError = null;
    });

    try {
      await _api.deleteConversation(conversationId);
      if (!mounted || generation != _operationGeneration) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted || generation != _operationGeneration) return;
      setState(() {
        _deleting = false;
        _deleteError = _VisibleError.from(error);
      });
    }
  }

  static String _stripDisplayPrefix(String text) =>
      text.replaceFirst(RegExp(r'^\[(Tu|Altri)\]\s*'), '');

  static String _normalizeSpeaker(String? speaker) =>
      const {'self', 'other', 'unknown'}.contains(speaker)
          ? speaker!
          : 'unknown';
}

class _CorrectionStatus extends StatelessWidget {
  const _CorrectionStatus({required this.result});

  final TranscriptionCorrectionResult result;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    if (result.queued) {
      return _StatusPanel(
        key: const Key('reanalysis-queued'),
        icon: CupertinoIcons.arrow_2_circlepath,
        color: palette.accent,
        message: 'Reprocessing memory',
      );
    }
    if (result.queueFailed) {
      return _StatusPanel(
        key: const Key('reanalysis-queue-failed'),
        icon: CupertinoIcons.exclamationmark_triangle,
        color: palette.red,
        message:
            'Correction saved, but reprocessing needs retry or attention.',
      );
    }
    return _StatusPanel(
      key: const Key('reanalysis-unchanged'),
      icon: CupertinoIcons.checkmark_circle,
      color: palette.text2,
      message: 'No reprocessing needed',
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    super.key,
    required this.icon,
    required this.color,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(AppTheme.tileRadius),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({
    super.key,
    required this.error,
    required this.retryKey,
    required this.retryLabel,
    required this.onRetry,
  });

  final _VisibleError error;
  final Key retryKey;
  final String retryLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = EchoPalette.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.red),
        borderRadius: BorderRadius.circular(AppTheme.tileRadius),
      ),
      child: Row(
        children: [
          Icon(CupertinoIcons.exclamationmark_circle, color: palette.red, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  error.message,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  error.retryable
                      ? 'You can retry this request.'
                      : 'Review the request before trying again.',
                  style: TextStyle(
                    color: palette.text2,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            key: retryKey,
            onPressed: onRetry,
            style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
            child: Text(retryLabel),
          ),
        ],
      ),
    );
  }
}

class _VisibleError {
  const _VisibleError(this.message, this.retryable);

  final String message;
  final bool retryable;

  factory _VisibleError.from(Object error) {
    if (error is ApiException) {
      return _VisibleError(error.message, error.retryable);
    }
    return const _VisibleError('The request could not be completed.', true);
  }
}