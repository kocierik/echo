import 'dart:async';

import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/models/segment.dart';
import 'package:echo_app/screens/home_screen.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const listening = DeviceStatus(
    connectionState: DeviceConnectionState.listening,
  );
  const muted = DeviceStatus(
    connectionState: DeviceConnectionState.muted,
  );
  const connecting = DeviceStatus(
    connectionState: DeviceConnectionState.connecting,
  );
  const offline = DeviceStatus(
    connectionState: DeviceConnectionState.offline,
  );

  testWidgets('four Today states fit supported light and dark viewports', (
    tester,
  ) async {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      for (final viewport in const [
        (size: Size(375, 812), textScale: 1.0),
        (size: Size(320, 812), textScale: 1.3),
      ]) {
        for (final status in [listening, muted, connecting, offline]) {
          await _pumpToday(
            tester,
            status: status,
            theme: theme,
            size: viewport.size,
            textScale: viewport.textScale,
          );
          expect(tester.takeException(), isNull);
        }
      }
    }
  });

  testWidgets('mute waits for telemetry acknowledgement before changing state', (
    tester,
  ) async {
    final writes = <bool>[];
    Future<void> setMuted(bool value) async => writes.add(value);

    await _pumpToday(tester, status: listening, setMuted: setMuted);
    await tester.tap(find.text('Mute microphone'));
    await tester.pump();

    expect(writes, [true]);
    expect(find.text('Listening'), findsOneWidget);
    expect(find.text('Mute microphone'), findsOneWidget);

    await _pumpToday(tester, status: muted, setMuted: setMuted);

    expect(find.text('Microphone muted'), findsOneWidget);
    expect(find.text('Resume listening'), findsOneWidget);
    expect(find.byKey(const Key('privacy-progress')), findsNothing);
  });

  testWidgets('resume command sends false', (tester) async {
    final writes = <bool>[];
    await _pumpToday(
      tester,
      status: muted,
      setMuted: (value) async => writes.add(value),
    );

    await tester.tap(find.text('Resume listening'));
    await tester.pump();

    expect(writes, [false]);
    expect(find.text('Microphone muted'), findsOneWidget);

    await _pumpToday(tester, status: listening, setMuted: (value) async {});
  });

  testWidgets('failed mute command exposes a retry without haptic success', (
    tester,
  ) async {
    var attempts = 0;
    await _pumpToday(
      tester,
      status: listening,
      setMuted: (_) async {
        attempts++;
        if (attempts == 1) throw StateError('write failed');
      },
    );

    await tester.tap(find.text('Mute microphone'));
    await tester.pump();

    expect(find.text('Echo could not update the microphone.'), findsOneWidget);
    expect(find.byKey(const Key('privacy-retry')), findsOneWidget);

    await tester.tap(find.byKey(const Key('privacy-retry')));
    await tester.pump();
    expect(attempts, 2);

    await _pumpToday(tester, status: muted, setMuted: (_) async {});
  });

  testWidgets('connecting disables the privacy action', (tester) async {
    final writes = <bool>[];
    await _pumpToday(
      tester,
      status: connecting,
      setMuted: (value) async => writes.add(value),
    );

    expect(find.text('Connecting…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('privacy-action')));
    await tester.pump();

    expect(writes, isEmpty);
  });

  testWidgets('offline reconnect delegates without optimistic listening state', (
    tester,
  ) async {
    var reconnects = 0;
    await _pumpToday(
      tester,
      status: offline,
      onReconnect: () async => reconnects++,
    );

    await tester.tap(find.text('Reconnect Echo'));
    await tester.pump();

    expect(reconnects, 1);
    expect(find.text('Echo is offline'), findsOneWidget);
    expect(find.text('Listening'), findsNothing);
  });

  testWidgets('latest memory shows loading, error, empty, and retry states', (
    tester,
  ) async {
    final pending = Completer<List<RecentSegment>>();
    await _pumpToday(tester, latestMemoryLoader: () => pending.future);
    expect(find.byKey(const Key('memory-loading')), findsOneWidget);

    pending.complete(const []);
    await tester.pump();
    expect(find.text('No completed memories yet.'), findsOneWidget);

    var attempts = 0;
    await _pumpToday(
      tester,
      latestMemoryLoader: () async {
        attempts++;
        if (attempts == 1) throw StateError('offline');
        return const [];
      },
    );
    await tester.pump();
    expect(find.text('Could not load the latest memory.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-retry')));
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('No completed memories yet.'), findsOneWidget);
  });

  testWidgets('latest memory chooses completed nonempty content and opens detail', (
    tester,
  ) async {
    var loads = 0;
    await _pumpToday(
      tester,
      latestMemoryLoader: () async {
        loads++;
        return [
          _segment(status: 'processing', text: 'Still processing'),
          _segment(id: 'empty', text: '   '),
          _segment(
            id: 'latest',
            text: '[You] Project Atlas is ready for review.',
            speaker: 'self',
          ),
        ];
      },
    );
    await tester.pump();

    expect(find.text('Project Atlas is ready for review.'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memory-content')));
    await tester.pumpAndSettle();
    expect(find.text('Transcript'), findsOneWidget);

    Navigator.of(tester.element(find.text('Transcript'))).pop();
    await tester.pumpAndSettle();
    expect(loads, 2);
  });

  testWidgets('segment upload refreshes latest memory once per event', (
    tester,
  ) async {
    final uploads = StreamController<int>();
    addTearDown(uploads.close);
    var loads = 0;
    await _pumpToday(
      tester,
      segmentUploadedStream: uploads.stream,
      latestMemoryLoader: () async {
        loads++;
        return const [];
      },
    );
    await tester.pump();
    expect(loads, 1);

    uploads.add(1);
    await tester.pump();
    await tester.pump();
    expect(loads, 2);
  });
}

Future<void> _pumpToday(
  WidgetTester tester, {
  DeviceStatus status = const DeviceStatus(
    connectionState: DeviceConnectionState.listening,
  ),
  Future<void> Function(bool)? setMuted,
  Future<void> Function()? onReconnect,
  Future<List<RecentSegment>> Function()? latestMemoryLoader,
  Stream<Object?>? segmentUploadedStream,
  ThemeData? theme,
  Size size = const Size(375, 812),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  await tester.pumpWidget(MaterialApp(
    theme: theme ?? AppTheme.light,
    home: MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: HomeScreen(
          deviceStatus: status,
          setMuted: setMuted ?? (_) async {},
          onReconnect: onReconnect,
          onAsk: () {},
          onTranscripts: () {},
          latestMemoryLoader: latestMemoryLoader ?? () async => const [],
          segmentUploadedStream: segmentUploadedStream,
          onMuteAcknowledged: () async {},
        ),
      ),
    ),
  ));
  await tester.pump();
}

RecentSegment _segment({
  String id = 'segment',
  String status = 'completed',
  String? text = 'A completed memory',
  String? speaker = 'other',
}) {
  return RecentSegment(
    id: id,
    receivedAt: DateTime(2026, 10, 2, 9, 30),
    recordedAt: DateTime(2026, 10, 2, 9, 29),
    durationMs: 1200,
    transcriptionStatus: status,
    text: text,
    speaker: speaker,
    conversationId: 'conversation',
  );
}