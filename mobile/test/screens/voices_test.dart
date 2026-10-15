import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/person.dart';
import 'package:echo_app/models/voice.dart';
import 'package:echo_app/screens/conversation_detail_screen.dart';
import 'package:echo_app/screens/settings/voice_settings_screen.dart';
import 'package:echo_app/services/api/api_service.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_memory_api.dart';

final class _VoiceMemoryApi extends FakeMemoryApi implements VoiceApi {
  _VoiceMemoryApi({super.details});

  final named = <(String, bool, String?, String?)>[];
  final rejected = <String>[];
  final deleted = <String>[];
  final enrollments = <String>[];
  VoiceProfiles profiles =
      const VoiceProfiles(fingerprintsEnabled: true, items: []);

  @override
  Future<VoiceProfiles> getVoiceProfiles() async => profiles;

  @override
  Future<VoiceEnrollment> enrollOwnVoice(
      DateTime startedAt, DateTime endedAt) async {
    final status = enrollments.isEmpty ? 'waiting' : 'done';
    enrollments.add(status);
    return VoiceEnrollment(status: status, segments: status == 'done' ? 3 : 0);
  }

  @override
  Future<void> deleteVoiceProfile(String id) async {
    deleted.add(id);
    profiles = VoiceProfiles(
      fingerprintsEnabled: true,
      items: profiles.items.where((v) => v.id != id).toList(),
    );
  }

  @override
  Future<int> nameVoice(String segmentId,
      {bool isSelf = false, String? personId, String? name}) async {
    named.add((segmentId, isSelf, personId, name));
    return 2;
  }

  @override
  Future<void> rejectVoice(String segmentId) async => rejected.add(segmentId);
}

TranscriptLine _line(String id,
        {String? speaker, String? name, String? match}) =>
    TranscriptLine(
      segmentId: id,
      recordedAt: DateTime(2026, 10, 14, 12, 30),
      status: 'completed',
      text: '[Others] Ti mando il preventivo.',
      speaker: speaker ?? 'other',
      speakerName: name,
      voiceMatch: match,
    );

void main() {
  test('a line is labelled with the recognised voice', () {
    expect(_line('a', speaker: 'self').speakerLabel, 'You');
    expect(_line('a').speakerLabel, 'Other');
    expect(_line('a', name: 'Marco', match: 'auto').speakerLabel, 'Marco');
    expect(
        _line('a', name: 'Marco', match: 'suggested').speakerLabel, 'Marco?');
    expect(_line('a', name: 'Marco', match: 'suggested').isSuggestion, isTrue);
  });

  group('transcript', () {
    late _VoiceMemoryApi api;

    setUp(() {
      api = _VoiceMemoryApi(details: {
        'c1': ConversationDetail(
          card: card('c1', startedAt: DateTime(2026, 10, 14, 12, 30)),
          lines: [
            _line('s1', name: 'Marco', match: 'suggested'),
            _line('s2'),
          ],
          entities: const [],
        ),
      })
        ..people = [const PersonSummary(id: 'p1', name: 'Ada Lovelace')];
    });

    Future<void> openTranscript(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ConversationDetailScreen(conversationId: 'c1', api: api),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transcript'));
      await tester.pumpAndSettle();
    }

    testWidgets('a suggested voice is confirmed or rejected', (tester) async {
      await openTranscript(tester);
      expect(find.text('Marco?'), findsOneWidget);

      await tester.tap(find.byKey(const Key('voice-yes-s1')));
      await tester.pumpAndSettle();
      expect(api.named.single, ('s1', false, null, 'Marco'));
      expect(find.text('Also recognised in 2 more lines.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('voice-no-s1')));
      await tester.pumpAndSettle();
      expect(api.rejected, ['s1']);
    });

    testWidgets('who is speaking: a person, me, or a new name', (tester) async {
      await openTranscript(tester);

      await tester.tap(find.byKey(const Key('speaker-s2')));
      await tester.pumpAndSettle();
      expect(find.text('Who is speaking?'), findsOneWidget);
      await tester.tap(find.text('Ada Lovelace'));
      await tester.pumpAndSettle();
      expect(api.named.last, ('s2', false, 'p1', null));

      await tester.tap(find.byKey(const Key('speaker-s2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-me')));
      await tester.pumpAndSettle();
      expect(api.named.last, ('s2', true, null, null));

      await tester.tap(find.byKey(const Key('speaker-s2')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('voice-new-name')), 'Giulia');
      await tester.pump();
      await tester.tap(find.byKey(const Key('voice-save-name')));
      await tester.pumpAndSettle();
      expect(api.named.last, ('s2', false, null, 'Giulia'));
    });

    testWidgets('no speaker actions without the voice api', (tester) async {
      final plain = FakeMemoryApi(details: api.details);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: ConversationDetailScreen(conversationId: 'c1', api: plain),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transcript'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('voice-yes-s1')), findsNothing);
      await tester.tap(find.byKey(const Key('speaker-s2')));
      await tester.pumpAndSettle();
      expect(find.text('Who is speaking?'), findsNothing);
    });
  });

  group('voices settings', () {
    testWidgets('lists the own voice and the people, and deletes one',
        (tester) async {
      final api = _VoiceMemoryApi()
        ..profiles = const VoiceProfiles(fingerprintsEnabled: true, items: [
          VoiceProfile(id: 'me', name: 'You', isSelf: true, sampleCount: 4),
          VoiceProfile(id: 'v1', name: 'Marco', isSelf: false, sampleCount: 1),
        ]);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: VoiceSettingsScreen(api: api),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Recorded'), findsOneWidget);
      expect(find.textContaining('Learned from 4 segments'), findsOneWidget);
      expect(find.text('Marco'), findsOneWidget);

      await tester.tap(find.byKey(const Key('voice-delete-v1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-delete-confirm')));
      await tester.pumpAndSettle();
      expect(api.deleted, ['v1']);
      expect(find.text('Marco'), findsNothing);
    });

    testWidgets('says when the server cannot recognise voices', (tester) async {
      final api = _VoiceMemoryApi()
        ..profiles = const VoiceProfiles(fingerprintsEnabled: false, items: []);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: VoiceSettingsScreen(api: api),
      ));
      await tester.pumpAndSettle();
      expect(
          find.text('Voice recognition is off on the server'), findsOneWidget);
      expect(find.text('Not recorded yet'), findsOneWidget);
    });

    testWidgets('recording the own voice waits for the server, then reports',
        (tester) async {
      final api = _VoiceMemoryApi();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: VoiceEnrollmentScreen(
          api: api,
          minimumReading: Duration.zero,
          wait: (_) async {},
        ),
      ));

      await tester.tap(find.byKey(const Key('enroll-start')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('enroll-done')));
      await tester.pumpAndSettle();

      expect(api.enrollments, ['waiting', 'done']);
      expect(find.text('Echo learned your voice from 3 segments.'),
          findsOneWidget);
      expect(find.byKey(const Key('enroll-close')), findsOneWidget);
    });
  });
}
