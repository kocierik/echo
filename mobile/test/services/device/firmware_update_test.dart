import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/services/device/device_protocol.dart';
import 'package:echo_app/services/device/firmware_update.dart';
import 'package:echo_app/theme/app_theme.dart';
import 'package:echo_app/widgets/firmware_update_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakeApi api;
  late _FakeLink link;
  late DeviceStatus device;
  late FirmwareUpdateController controller;
  final image = Uint8List.fromList(List<int>.generate(1050, (i) => (i * 7) % 256));

  // The release key's signature, as the server gives it (hex r||s)
  final signature = List<int>.generate(64, (i) => 255 - i);
  final signatureHex =
      signature.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  FirmwareRelease release(String version, [Uint8List? bytes, String? signed]) =>
      FirmwareRelease(
        version: version,
        sizeBytes: (bytes ?? image).length,
        sha256: sha256.convert(bytes ?? image).toString(),
        signature: signed,
        notes: 'Firmware updates',
      );

  setUp(() {
    api = _FakeApi()
      ..release = release('0.6.0')
      ..image = image;
    link = _FakeLink();
    device = const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
      protocolVersion: 4,
      firmwareVersion: '0.5.0',
    );
    controller = FirmwareUpdateController(
      api: api,
      link: link,
      device: () => device,
      syncTimeout: const Duration(milliseconds: 300),
      statusTimeout: const Duration(seconds: 2),
      restartTimeout: const Duration(seconds: 2),
      pollInterval: const Duration(milliseconds: 10),
    );
  });

  tearDown(() async {
    controller.dispose();
    await link.close();
  });

  test('versions compare by number', () {
    expect(isNewerFirmware('0.10.0', '0.9.9'), isTrue);
    expect(isNewerFirmware('1.0.0', '0.99.99'), isTrue);
    expect(isNewerFirmware('0.5.0', '0.5.0'), isFalse);
    expect(isNewerFirmware('0.4.9', '0.5.0'), isFalse);
    expect(isNewerFirmware('0.6.0', null), isFalse);
    expect(isNewerFirmware('0.6', '0.5.0'), isFalse);
  });

  test('a newer firmware is offered, asking the server at most once an hour', () async {
    await controller.check();
    expect(controller.value.phase, FirmwareUpdatePhase.available);
    expect(controller.value.release!.version, '0.6.0');

    await controller.check();
    expect(api.latestCalls, 1);
    await controller.check(force: true);
    expect(api.latestCalls, 2);
  });

  test('the wearable decides what is shown, without asking the server again', () async {
    await controller.check();

    device = device.copyWith(firmwareVersion: '0.6.0');
    controller.deviceChanged();
    expect(controller.value.phase, FirmwareUpdatePhase.idle);

    // A firmware from before updates over Bluetooth never says its version
    device = const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
      protocolVersion: 3,
    );
    controller.deviceChanged();
    expect(controller.value.phase, FirmwareUpdatePhase.needsCable);

    device = const DeviceStatus(connectionState: DeviceConnectionState.offline);
    controller.deviceChanged();
    expect(controller.value.phase, FirmwareUpdatePhase.idle);
    expect(api.latestCalls, 1);
  });

  test('installs in order and is done when the wearable comes back with it', () async {
    await controller.check();
    final phases = <FirmwareUpdatePhase>[];
    controller.addListener(() {
      if (phases.isEmpty || phases.last != controller.value.phase) {
        phases.add(controller.value.phase);
      }
    });

    await controller.install();

    expect(controller.value.phase, FirmwareUpdatePhase.done);
    expect(controller.value.message, contains('0.6.0'));
    expect(phases, [
      FirmwareUpdatePhase.syncing,
      FirmwareUpdatePhase.downloading,
      FirmwareUpdatePhase.sending,
      FirmwareUpdatePhase.restarting,
      FirmwareUpdatePhase.done,
    ]);
    expect(link.beganSize, image.length);
    expect(link.beganSha, sha256.convert(image).bytes);
    // A wearable from before signed updates gets the frame it knows
    expect(link.beganSignature, isNull);
    expect(link.offsets, List<int>.generate(11, (i) => i * 100));
    expect(link.written, image);
  });

  test('a wearable that checks signatures gets the signature of the release key', () async {
    device = device.copyWith(protocolVersion: 6);
    api.release = release('0.6.0', null, signatureHex);
    await controller.check();

    await controller.install();

    expect(controller.value.phase, FirmwareUpdatePhase.done);
    expect(link.beganSignature, signature);
  });

  test('an unsigned release never reaches a wearable that checks signatures', () async {
    device = device.copyWith(protocolVersion: 6);
    await controller.check();

    await controller.install();

    expect(controller.value.phase, FirmwareUpdatePhase.failed);
    expect(controller.value.message, contains('not signed'));
    expect(link.beganSize, isNull);
  });

  test('waits for the wearable to send what it holds, then gives up', () async {
    device = device.copyWith(bufferCount: 2, bufferBytes: 4000);
    await controller.check();

    await controller.install();

    expect(controller.value.phase, FirmwareUpdatePhase.failed);
    expect(controller.value.message, contains('still has audio'));
    expect(link.beganSize, isNull);
  });

  test('starts once the audio is sent', () async {
    device = device.copyWith(bufferCount: 1, bufferBytes: 900);
    await controller.check();
    Timer(const Duration(milliseconds: 50), () {
      device = device.copyWith(bufferCount: 0, bufferBytes: 0);
    });

    await controller.install();

    expect(controller.value.phase, FirmwareUpdatePhase.done);
  });

  test('a damaged download never reaches the wearable', () async {
    api.image = Uint8List.fromList(image)..[10] ^= 1;
    await controller.check();

    await controller.install();

    expect(controller.value.phase, FirmwareUpdatePhase.failed);
    expect(controller.value.message, contains('download arrived damaged'));
    expect(link.beganSize, isNull);
  });

  test('the wearable refusing to start is explained', () async {
    link.beginStatus = const OtaStatus(OtaState.failed, 3, 0);
    await controller.check();

    await controller.install();

    expect(controller.value.phase, FirmwareUpdatePhase.failed);
    expect(controller.value.message, contains('battery is too low'));
    expect(link.offsets, isEmpty);
  });

  test('a failure reported mid-transfer stops the writes', () async {
    link.failFromOffset = 300;
    await controller.check();

    await controller.install();

    expect(controller.value.phase, FirmwareUpdatePhase.failed);
    expect(controller.value.message, contains('damaged'));
    expect(link.written.length, lessThan(image.length));
  });

  test('a wearable back on its previous firmware is reported', () async {
    link.restartVersion = [0, 5, 0];
    await controller.check();

    await controller.install();

    expect(controller.value.phase, FirmwareUpdatePhase.failed);
    expect(controller.value.message, contains('went back to 0.5.0'));
  });

  test('cancel stops the transfer and tells the wearable', () async {
    await controller.check();
    link.onChunk = (offset) {
      if (offset == 200) unawaited(controller.cancel());
    };

    await controller.install();

    expect(controller.value.phase, FirmwareUpdatePhase.failed);
    expect(controller.value.message, 'Update cancelled.');
    expect(link.aborts, greaterThanOrEqualTo(1));
    expect(link.written.length, lessThan(image.length));

    controller.reset();
    expect(controller.value.phase, FirmwareUpdatePhase.available);
  });

  Future<void> pumpSection(WidgetTester tester) => tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: FirmwareUpdateSection(controller: controller),
          ),
        ),
      ));

  testWidgets('Device offers the update, asks first, and shows it through', (tester) async {
    await controller.check();
    await pumpSection(tester);
    expect(find.text('Firmware 0.6.0 is ready'), findsOneWidget);
    expect(find.text('Firmware updates'), findsOneWidget);

    await tester.tap(find.byKey(const Key('firmware-update')));
    await tester.pumpAndSettle();
    expect(find.text('Update Echo to 0.6.0?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('firmware-confirm')));
    await tester.pump();
    expect(find.byKey(const Key('firmware-progress-label')), findsOneWidget);
    expect(find.text('Keep the app open and Echo nearby.'), findsOneWidget);

    for (var i = 0; i < 40 && controller.value.busy; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const Key('firmware-done')), findsOneWidget);
    expect(find.text('Echo is up to date (0.6.0).'), findsOneWidget);
  });

  testWidgets('an old firmware is told to use the cable; a failure can be retried',
      (tester) async {
    device = const DeviceStatus(
      connectionState: DeviceConnectionState.listening,
      protocolVersion: 3,
    );
    await controller.check();
    await pumpSection(tester);
    expect(find.byKey(const Key('firmware-needs-cable')), findsOneWidget);
    expect(find.byKey(const Key('firmware-update')), findsNothing);

    device = device.copyWith(protocolVersion: 4, firmwareVersion: '0.5.0');
    controller.deviceChanged();
    api.image = Uint8List.fromList(image)..[0] ^= 1;
    await tester.runAsync(controller.install);
    await tester.pump();
    expect(find.byKey(const Key('firmware-failed')), findsOneWidget);

    await tester.tap(find.byKey(const Key('firmware-retry')));
    await tester.pump();
    expect(find.byKey(const Key('firmware-update')), findsOneWidget);
  });
}

final class _FakeApi implements FirmwareApi {
  FirmwareRelease? release;
  late Uint8List image;
  int latestCalls = 0;

  @override
  Future<FirmwareRelease?> latestFirmware() async {
    latestCalls++;
    return release;
  }

  @override
  Future<Uint8List> downloadFirmware(String version) async => image;
}

/// A wearable that writes what it gets, reports DONE after the last byte and comes
/// back reporting [restartVersion].
final class _FakeLink implements FirmwareLink {
  final _statuses = StreamController<OtaStatus>.broadcast();
  final _infos = StreamController<DeviceInfo>.broadcast();
  OtaStatus beginStatus = const OtaStatus(OtaState.receiving, 0, 0);
  int? failFromOffset;
  List<int> restartVersion = [0, 6, 0];
  void Function(int offset)? onChunk;

  int? beganSize;
  List<int>? beganSha;
  List<int>? beganSignature;
  final offsets = <int>[];
  final written = <int>[];
  int aborts = 0;

  @override
  bool get canUpdateFirmware => true;

  @override
  int get firmwareChunkSize => 100;

  @override
  Stream<OtaStatus> get otaStatusStream => _statuses.stream;

  @override
  Stream<DeviceInfo> get deviceInfoStream => _infos.stream;

  @override
  Future<void> beginFirmwareUpdate(
      int size, List<int> sha256, List<int>? signature) async {
    beganSize = size;
    beganSha = sha256;
    beganSignature = signature;
    scheduleMicrotask(() => _statuses.add(beginStatus));
  }

  @override
  Future<void> writeFirmwareChunk(int offset, List<int> bytes) async {
    offsets.add(offset);
    written.addAll(bytes);
    onChunk?.call(offset);
    final failFrom = failFromOffset;
    if (failFrom != null && offset >= failFrom) {
      _statuses.add(OtaStatus(OtaState.failed, 6, written.length));
      return;
    }
    if (written.length == beganSize) {
      _statuses.add(OtaStatus(OtaState.done, 0, written.length));
      // The restart takes a moment: the app is listening by then
      Timer(const Duration(milliseconds: 150), () {
        _infos.add(DeviceInfo(
          protocolVersion: 4,
          firmwareMajor: restartVersion[0],
          firmwareMinor: restartVersion[1],
          firmwarePatch: restartVersion[2],
        ));
      });
    }
  }

  @override
  Future<void> abortFirmwareUpdate() async => aborts++;

  Future<void> close() async {
    await _statuses.close();
    await _infos.close();
  }
}
