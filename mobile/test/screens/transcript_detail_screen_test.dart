import 'dart:async';

import 'package:echo_app/models/segment.dart';
import 'package:echo_app/screens/transcript_detail_screen.dart';
import 'package:echo_app/services/api_exception.dart';
import 'package:echo_app/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('unchanged and empty transcript cannot be saved', (tester) async {
    final api = _FakeTranscriptMemoryApi();
    await _pumpDetail(tester, api);

    expect(_saveButton(tester).onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('transcript-text-field')),
      '   ',
    );
    await tester.pump();

    expect(_saveButton(tester).onPressed, isNull);
    expect(find.text('Transcript text is required.'), findsOneWidget);
  });

  testWidgets('speaker-only correction sends the full trimmed text',
      (tester) async {
    final api = _FakeTranscriptMemoryApi();
    await _pumpDetail(tester, api);

    await tester.tap(find.byKey(const Key('speaker-other')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-transcript')));
    await tester.pumpAndSettle();

    expect(api.corrections, [
      const _CorrectionCall('segment-1', 'Original memory', 'other'),
    ]);
  });

  testWidgets('text correction sends current text and keeps server text visible',
      (tester) async {
    final api = _FakeTranscriptMemoryApi(
      correctionResult: _result(text: 'Canonical memory'),
    );
    await _pumpDetail(tester, api);

    await tester.enterText(
      find.byKey(const Key('transcript-text-field')),
      '  Edited memory  ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-transcript')));
    await tester.pumpAndSettle();

    expect(api.corrections, [
      const _CorrectionCall('segment-1', 'Edited memory', 'self'),
    ]);
    expect(find.text('Canonical memory'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);
  });

  testWidgets('queued correction shows reprocessing status', (tester) async {
    final api = _FakeTranscriptMemoryApi(
      correctionResult: _result(reanalysisStatus: 'queued'),
    );
    await _pumpDetail(tester, api);

    await tester.enterText(
      find.byKey(const Key('transcript-text-field')),
      'Edited memory',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-transcript')));
    await tester.pumpAndSettle();

    expect(find.text('Reprocessing memory'), findsOneWidget);
  });

  testWidgets('queue failure preserves correction and shows warning',
      (tester) async {
    final api = _FakeTranscriptMemoryApi(
      correctionResult: _result(
        text: 'Saved correction',
        reanalysisStatus: 'queue_failed',
      ),
    );
    await _pumpDetail(tester, api);

    await tester.enterText(
      find.byKey(const Key('transcript-text-field')),
      'Edited memory',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-transcript')));
    await tester.pumpAndSettle();

    expect(find.text('Saved correction'), findsOneWidget);
    expect(
      find.text(
        'Correction saved, but reprocessing needs retry or attention.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('correction failure retains edits and allows retry',
      (tester) async {
    var attempts = 0;
    final api = _FakeTranscriptMemoryApi(
      correctionHandler: (segmentId, text, speaker) {
        attempts++;
        if (attempts == 1) {
          return Future.error(const ApiException(
            statusCode: 503,
            code: 'server',
            message: 'Correction unavailable',
            retryable: true,
          ));
        }
        return Future.value(_result(text: text));
      },
    );
    await _pumpDetail(tester, api);

    await tester.enterText(
      find.byKey(const Key('transcript-text-field')),
      'Edited memory',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-transcript')));
    await tester.pumpAndSettle();

    expect(find.text('Correction unavailable'), findsOneWidget);
    expect(find.text('Edited memory'), findsOneWidget);

    await tester.tap(find.byKey(const Key('retry-save-transcript')));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('Correction unavailable'), findsNothing);
  });

  testWidgets('cancelling deletion makes no API call', (tester) async {
    final api = _FakeTranscriptMemoryApi();
    await _pumpDetail(tester, api);

    await tester.ensureVisible(find.byKey(const Key('delete-conversation')));
    await tester.tap(find.byKey(const Key('delete-conversation')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel-delete-conversation')));
    await tester.pumpAndSettle();

    expect(api.deletions, isEmpty);
    expect(find.byKey(const Key('transcript-detail-screen')), findsOneWidget);
  });

  testWidgets('successful deletion pops only after the request completes',
      (tester) async {
    final deleteCompleter = Completer<void>();
    final api = _FakeTranscriptMemoryApi(
      deleteHandler: (_) => deleteCompleter.future,
    );
    await _pumpDetail(tester, api, withHost: true);
    await tester.tap(find.byKey(const Key('open-transcript-detail')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('delete-conversation')));
    await tester.tap(find.byKey(const Key('delete-conversation')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-conversation')));
    await tester.pump();

    expect(find.byKey(const Key('transcript-detail-screen')), findsOneWidget);
    expect(find.byKey(const Key('delete-conversation-progress')), findsOneWidget);

    deleteCompleter.complete();
    await tester.pumpAndSettle();

    expect(api.deletions, ['conversation-1']);
    expect(find.byKey(const Key('transcript-detail-screen')), findsNothing);
    expect(find.text('deleted:true'), findsOneWidget);
  });

  testWidgets('failed deletion retains data and allows retry', (tester) async {
    var attempts = 0;
    final api = _FakeTranscriptMemoryApi(
      deleteHandler: (_) {
        attempts++;
        if (attempts == 1) {
          return Future.error(const ApiException(
            statusCode: 503,
            code: 'server',
            message: 'Delete unavailable',
            retryable: true,
          ));
        }
        return Future.value();
      },
    );
    await _pumpDetail(tester, api, withHost: true);
    await tester.tap(find.byKey(const Key('open-transcript-detail')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('delete-conversation')));
    await tester.tap(find.byKey(const Key('delete-conversation')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-conversation')));
    await tester.pumpAndSettle();

    expect(find.text('Delete unavailable'), findsOneWidget);
    expect(find.text('Original memory'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const Key('retry-delete-conversation')),
    );
    await tester.tap(find.byKey(const Key('retry-delete-conversation')));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('deleted:true'), findsOneWidget);
  });
}

Future<void> _pumpDetail(
  WidgetTester tester,
  TranscriptMemoryApi api, {
  bool withHost = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: withHost
          ? _DetailHost(api: api)
          : TranscriptDetailScreen(segment: _segment(), api: api),
    ),
  );
  await tester.pump();
}

FilledButton _saveButton(WidgetTester tester) =>
    tester.widget(find.byKey(const Key('save-transcript')));

RecentSegment _segment() => RecentSegment(
      id: 'segment-1',
      receivedAt: DateTime.parse('2026-10-02T12:00:01Z'),
      recordedAt: DateTime.parse('2026-10-02T12:00:00Z'),
      durationMs: 1200,
      transcriptionStatus: 'completed',
      text: '[Tu] Original memory',
      speaker: 'self',
      conversationId: 'conversation-1',
    );

TranscriptionCorrectionResult _result({
  String text = 'Edited memory',
  String speaker = 'self',
  String reanalysisStatus = 'unchanged',
}) =>
    TranscriptionCorrectionResult(
      segmentId: 'segment-1',
      transcriptionId: 'transcription-1',
      text: text,
      speakerLabel: speaker,
      updatedAt: DateTime.parse('2026-10-02T12:05:00Z'),
      reanalysisStatus: reanalysisStatus,
    );

final class _DetailHost extends StatefulWidget {
  const _DetailHost({required this.api});

  final TranscriptMemoryApi api;

  @override
  State<_DetailHost> createState() => _DetailHostState();
}

final class _DetailHostState extends State<_DetailHost> {
  bool? _deleted;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Text('deleted:${_deleted ?? false}'),
          TextButton(
            key: const Key('open-transcript-detail'),
            onPressed: () async {
              final deleted = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => TranscriptDetailScreen(
                    segment: _segment(),
                    api: widget.api,
                  ),
                ),
              );
              if (mounted) setState(() => _deleted = deleted);
            },
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }
}

final class _CorrectionCall {
  const _CorrectionCall(this.segmentId, this.text, this.speaker);

  final String segmentId;
  final String text;
  final String speaker;

  @override
  bool operator ==(Object other) =>
      other is _CorrectionCall &&
      segmentId == other.segmentId &&
      text == other.text &&
      speaker == other.speaker;

  @override
  int get hashCode => Object.hash(segmentId, text, speaker);
}

final class _FakeTranscriptMemoryApi implements TranscriptMemoryApi {
  _FakeTranscriptMemoryApi({
    TranscriptionCorrectionResult? correctionResult,
    this.correctionHandler,
    this.deleteHandler,
  }) : correctionResult = correctionResult ?? _result();

  final TranscriptionCorrectionResult correctionResult;
  final Future<TranscriptionCorrectionResult> Function(
    String segmentId,
    String text,
    String speaker,
  )? correctionHandler;
  final Future<void> Function(String conversationId)? deleteHandler;
  final List<_CorrectionCall> corrections = [];
  final List<String> deletions = [];

  @override
  Future<TranscriptionCorrectionResult> correctTranscription(
    String segmentId,
    String text,
    String speaker,
  ) {
    corrections.add(_CorrectionCall(segmentId, text, speaker));
    final handler = correctionHandler;
    if (handler != null) return handler(segmentId, text, speaker);
    return Future.value(correctionResult);
  }

  @override
  Future<void> deleteConversation(String conversationId) {
    deletions.add(conversationId);
    final handler = deleteHandler;
    if (handler != null) return handler(conversationId);
    return Future.value();
  }
}