import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/models/memory.dart';
import 'package:echo_app/models/session_state.dart';
import 'package:echo_app/screens/conversation_detail_screen.dart';
import 'package:echo_app/screens/settings/privacy_settings_screen.dart';
import 'package:echo_app/services/app/app_controller.dart';
import 'package:echo_app/services/app/sharing.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/utils/conversation_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_memory_api.dart';

final class _FakeSharing implements Sharing {
  final texts = <(String, String?)>[];
  final files = <(String, int)>[];

  @override
  Future<void> shareText(String text, {String? subject}) async =>
      texts.add((text, subject));

  @override
  Future<void> shareFile(String fileName, List<int> contents,
          {String? subject}) async =>
      files.add((fileName, contents.length));
}

ConversationDetail _detail() => ConversationDetail(
      card: ConversationCard(
        id: 'c1',
        title: 'Pranzo con Ada',
        summary: 'Ada propone Atlas.',
        startedAt: DateTime(2026, 10, 15, 12, 30),
        endedAt: DateTime(2026, 10, 15, 13, 15),
      ),
      lines: [
        TranscriptLine(
          segmentId: 's1',
          recordedAt: DateTime(2026, 10, 15, 12, 30),
          status: 'completed',
          text: '[You] Domani chiamo Ada.',
          speaker: 'self',
        ),
        TranscriptLine(
          segmentId: 's2',
          recordedAt: DateTime(2026, 10, 15, 12, 31),
          status: 'completed',
          text: '[Others] Perfetto.',
          speaker: 'other',
          speakerName: 'Ada',
          voiceMatch: 'auto',
        ),
        TranscriptLine(
          segmentId: 's3',
          recordedAt: DateTime(2026, 10, 15, 12, 32),
          status: 'pending',
        ),
      ],
      entities: const [
        MemoryEntity(id: 't1', type: 'task', name: 'Chiamare Ada')
      ],
    );

void main() {
  test('a conversation as text', () {
    final text = conversationAsText(_detail(), DateTime(2026, 10, 15, 18));
    expect(text, '''# Pranzo con Ada
Today · 12:30–13:15

Ada propone Atlas.

## Tasks
- Chiamare Ada

## Transcript
12:30 You: Domani chiamo Ada.
12:31 Ada: Perfetto.''');
  });

  testWidgets('the conversation share button shares it as text',
      (tester) async {
    final sharing = _FakeSharing();
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: ConversationDetailScreen(
        conversationId: 'c1',
        api: FakeMemoryApi(details: {'c1': _detail()}),
        sharing: sharing,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('conversation-share')));
    await tester.pump();

    expect(sharing.texts.single.$1, startsWith('# Pranzo con Ada'));
    expect(sharing.texts.single.$2, 'Pranzo con Ada');
  });

  testWidgets('Export my data shares the export as a file', (tester) async {
    final sharing = _FakeSharing();
    SharedPreferences.setMockInitialValues({});
    final controller = AppController(
      initialDevice:
          const DeviceStatus(connectionState: DeviceConnectionState.listening),
      deviceStates: const Stream.empty(),
      initialSession: const SessionState(SessionStatus.loggedIn),
      sessionStates: const Stream.empty(),
      preferences: SharedPreferencesAppPreferences(
          await SharedPreferences.getInstance()),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: PrivacySettingsScreen(
        appController: controller,
        exportData: () async => [1, 2, 3],
        sharing: sharing,
        clock: () => DateTime(2026, 10, 15, 9),
      ),
    ));

    await tester.tap(find.byKey(const Key('privacy-export')));
    await tester.pumpAndSettle();

    expect(sharing.files.single, ('echo-export-2026-10-15.json', 3));
  });
}
