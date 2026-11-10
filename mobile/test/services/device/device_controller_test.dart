import 'dart:async';

import 'package:echo_app/models/device_status.dart';
import 'package:echo_app/services/device/device_ble_port.dart';
import 'package:echo_app/services/device/device_controller.dart';
import 'package:echo_app/services/device/device_identity_store.dart';
import 'package:echo_app/services/device/device_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceController', () {
    test('starts unpaired when no identity is saved', () async {
      final fixture = _Fixture();

      await fixture.controller.start();

      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.unpaired);
      expect(fixture.ble.savedConnectIds, isEmpty);
    });

    test('a saved wearable is not reconnected while no one is signed in', () async {
      // Signed out (the welcome): segments could not be uploaded, the wearable's
      // memory would fill and drop them, one notification each
      final fixture = _Fixture(savedId: 'echo-1', canConnect: false);

      await fixture.controller.start();

      expect(fixture.ble.savedConnectIds, isEmpty);
      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.unpaired);
    });

    test('manual pairing saves identity only after the port is ready', () async {
      final fixture = _Fixture();
      final pairing = Completer<String>();
      fixture.ble.pairing = pairing;
      await fixture.controller.start();

      final operation = fixture.controller.pair();
      fixture.ble.emitPhase(DeviceBlePhase.scanning);
      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.scanning);
      fixture.ble.emitPhase(DeviceBlePhase.connecting);
      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.connecting);
      fixture.ble.emitPhase(DeviceBlePhase.bonding);
      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.bonding);
      expect(fixture.store.savedIds, isEmpty);

      fixture.ble.emitTelemetry(_telemetry(muted: true));
      pairing.complete('echo-1');
      await operation;

      expect(fixture.store.savedIds, ['echo-1']);
      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.muted);
    });

    test('saved launch schedules an immediate auto-connect by remote ID',
        () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      await fixture.controller.start();

      expect(fixture.scheduler.delays, [Duration.zero]);
      fixture.scheduler.fire(0);
      await _flush();

      expect(fixture.ble.savedConnectIds, ['saved-echo']);
      expect(fixture.ble.pairCalls, 0);
    });

    test('saved connect reports ready only after port setup completes',
        () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      final connected = Completer<void>();
      fixture.ble.savedConnection = connected;
      await fixture.controller.start();

      fixture.scheduler.fire(0);
      await _flush();
      fixture.ble.emitPhase(DeviceBlePhase.connecting);

      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.reconnecting);
      connected.complete();
      await _flush();
      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.listening);
    });

    test('unauthorized adapter starts in bluetoothOff', () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      fixture.ble.setAdapter(DeviceAdapterState.unauthorized);

      await fixture.controller.start();

      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.bluetoothOff);
      expect(fixture.scheduler.delays, isEmpty);
    });

    test('retries at 0, 2, 5, 10, 30 then stays offline at 30 seconds',
        () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      fixture.ble.connectError = StateError('unavailable');
      await fixture.controller.start();

      for (var index = 0; index < 6; index++) {
        fixture.scheduler.fire(index);
        await _flush();
      }

      expect(fixture.scheduler.delays, const [
        Duration.zero,
        Duration(seconds: 2),
        Duration(seconds: 5),
        Duration(seconds: 10),
        Duration(seconds: 30),
        Duration(seconds: 30),
        Duration(seconds: 30),
      ]);
      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.offline);
    });

    test('bluetooth off cancels retry and on resumes immediately', () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      await fixture.controller.start();
      final pending = fixture.scheduler.handles.single;

      fixture.ble.emitAdapter(DeviceAdapterState.off);
      await _flush();

      expect(pending.isCancelled, isTrue);
      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.bluetoothOff);

      fixture.ble.emitAdapter(DeviceAdapterState.on);
      await _flush();
      expect(fixture.scheduler.delays.last, Duration.zero);
    });

    test('bluetooth off cancels an active connect before resuming', () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      final connected = Completer<void>();
      fixture.ble.savedConnection = connected;
      fixture.ble.onDisconnect = () {
        if (!connected.isCompleted) {
          connected.completeError(StateError('adapter off'));
        }
      };
      await fixture.controller.start();
      fixture.scheduler.fire(0);
      await _flush();

      fixture.ble.emitAdapter(DeviceAdapterState.off);
      fixture.ble.emitAdapter(DeviceAdapterState.on);
      await _flush();
      await _flush();

      expect(fixture.ble.disconnectCalls, 1);
      expect(fixture.scheduler.delays, [Duration.zero, Duration.zero]);
    });

    test('a ready-session disconnect starts a fresh immediate reconnect',
        () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      await fixture.controller.start();
      fixture.scheduler.fire(0);
      await _flush();
      fixture.ble.emitTelemetry(_telemetry());
      fixture.ble.emitPhase(DeviceBlePhase.ready);
      await _flush();

      fixture.ble.emitPhase(DeviceBlePhase.disconnected);
      await _flush();

      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.reconnecting);
      expect(fixture.scheduler.delays.last, Duration.zero);
    });

    test('telemetry controls listening and muted state and retains metrics',
        () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      await fixture.controller.start();

      fixture.ble.emitTelemetry(_telemetry(
        muted: false,
        batteryPercent: 82,
        bufferCount: 3,
        bufferBytes: 12000,
        droppedSegments: 7,
        overflowed: true,
      ));

      expect(
        fixture.controller.state,
        const DeviceStatus(
          connectionState: DeviceConnectionState.listening,
          batteryPercent: 82,
          bufferCount: 3,
          bufferBytes: 12000,
          droppedSegments: 7,
          overflowed: true,
        ),
      );

      fixture.ble.emitTelemetry(_telemetry(muted: true));
      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.muted);
    });

    test('device info is retained in connected status', () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      await fixture.controller.start();

      fixture.ble.emitInfo(const DeviceInfo(
        protocolVersion: 2,
        firmwareMajor: 1,
        firmwareMinor: 4,
        firmwarePatch: 7,
      ));
      fixture.ble.emitTelemetry(_telemetry(batteryPercent: 82));

      expect(fixture.controller.state.protocolVersion, 2);
      expect(fixture.controller.state.firmwareVersion, '1.4.7');
      expect(fixture.controller.state.batteryPercent, 82);
    });

    test('setMuted keeps state unchanged until telemetry acknowledgement', () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      await fixture.controller.start();
      fixture.ble.emitTelemetry(_telemetry());

      await fixture.controller.setMuted(true);

      expect(fixture.ble.muteWrites, [true]);
      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.listening);
      fixture.ble.emitTelemetry(_telemetry(muted: true));
      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.muted);
    });

    test('forget clears identity only after the port future succeeds',
        () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      final forgotten = Completer<void>();
      fixture.ble.forgetResult = forgotten.future;
      await fixture.controller.start();

      final operation = fixture.controller.forget();
      await _flush();
      expect(fixture.store.clearCalls, 0);

      forgotten.complete();
      await operation;

      expect(fixture.store.clearCalls, 1);
      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.unpaired);
    });

    test('forget failure retains identity and telemetry in error state',
        () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      await fixture.controller.start();
      fixture.ble.emitTelemetry(_telemetry(
        batteryPercent: 61,
        bufferCount: 2,
        droppedSegments: 4,
      ));
      fixture.ble.forgetResult = Future<void>.error(StateError('no ack'));

      await expectLater(fixture.controller.forget(), throwsStateError);

      expect(fixture.store.clearCalls, 0);
      expect(fixture.store.value, 'saved-echo');
      expect(fixture.controller.state.connectionState,
          DeviceConnectionState.error);
      expect(fixture.controller.state.batteryPercent, 61);
      expect(fixture.controller.state.bufferCount, 2);
      expect(fixture.controller.state.droppedSegments, 4);
      expect(fixture.controller.state.error, contains('no ack'));
    });

    test('dispose cancels pending work and ignores later stream events',
        () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      await fixture.controller.start();
      final pending = fixture.scheduler.handles.single;
      final states = <DeviceStatus>[];
      final subscription = fixture.controller.stateStream.listen(states.add);

      await fixture.controller.dispose();
      final stateAtDispose = fixture.controller.state;
      fixture.ble.emitAdapter(DeviceAdapterState.off);
      fixture.ble.emitTelemetry(_telemetry(muted: true));
      pending.fire();
      await _flush();

      expect(pending.isCancelled, isTrue);
      expect(fixture.ble.disposeCalls, 1);
      expect(fixture.ble.infoHasListener, isFalse);
      expect(fixture.controller.state, stateAtDispose);
      expect(states, isEmpty);
      await subscription.cancel();
    });

    test('turning off is kept over telemetry; off is kept through the disconnect', () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      await fixture.controller.start();
      fixture.scheduler.fire(0);
      await _flush();
      fixture.ble.emitPhase(DeviceBlePhase.ready);
      fixture.ble.emitTelemetry(_telemetry(bufferCount: 2));

      final turningOff = fixture.controller.turnOff();
      await _flush();
      expect(fixture.ble.powerOffWrites, 1);
      fixture.ble.emitPower(DevicePowerState.turningOff);
      await turningOff;
      expect(fixture.controller.state.connectionState, DeviceConnectionState.turningOff);

      fixture.ble.emitTelemetry(_telemetry(bufferCount: 1));
      expect(fixture.controller.state.connectionState, DeviceConnectionState.turningOff);
      expect(fixture.controller.state.bufferCount, 1);

      fixture.ble.emitPower(DevicePowerState.off);
      expect(fixture.controller.state.connectionState, DeviceConnectionState.off);
      fixture.ble.emitPhase(DeviceBlePhase.disconnected);
      await _flush();
      expect(fixture.controller.state.connectionState, DeviceConnectionState.off);

      // Turned on again: it reconnects and listens
      fixture.ble.emitPhase(DeviceBlePhase.ready);
      expect(fixture.controller.state.connectionState, DeviceConnectionState.listening);
    });

    test('a cancelled turn-off listens again, or stays muted', () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      await fixture.controller.start();
      fixture.ble.emitTelemetry(_telemetry(muted: true));
      final turningOff = fixture.controller.turnOff();
      fixture.ble.emitPower(DevicePowerState.turningOff);
      await turningOff;

      await fixture.controller.cancelTurnOff();
      expect(fixture.ble.cancelPowerOffWrites, 1);
      fixture.ble.emitPower(DevicePowerState.on);
      expect(fixture.controller.state.connectionState, DeviceConnectionState.muted);
    });

    test('Echo refuses to turn off while updating', () async {
      final fixture = _Fixture(savedId: 'saved-echo');
      await fixture.controller.start();
      fixture.ble.emitTelemetry(_telemetry());

      final turningOff = fixture.controller.turnOff();
      fixture.ble.emitPower(DevicePowerState.refused);

      await expectLater(
        turningOff,
        throwsA(isA<StateError>().having(
            (error) => error.message, 'message', DeviceController.refusedUpdatingMessage)),
      );
      expect(fixture.controller.state.connectionState, DeviceConnectionState.listening);
    });
  });
}

DeviceTelemetry _telemetry({
  bool muted = false,
  int? batteryPercent,
  int bufferCount = 0,
  int bufferBytes = 0,
  int droppedSegments = 0,
  bool overflowed = false,
}) {
  return DeviceTelemetry(
    muted: muted,
    overflowed: overflowed,
    batteryPercent: batteryPercent,
    bufferCount: bufferCount,
    bufferBytes: bufferBytes,
    droppedSegments: droppedSegments,
  );
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _Fixture {
  _Fixture({String? savedId, bool canConnect = true})
      : ble = _FakeDeviceBlePort(),
        store = _FakeIdentityStore(savedId),
        scheduler = _FakeScheduler() {
    controller = DeviceController(
      ble: ble,
      identityStore: store,
      scheduleRetry: scheduler.schedule,
      canConnect: () async => canConnect,
    );
  }

  final _FakeDeviceBlePort ble;
  final _FakeIdentityStore store;
  final _FakeScheduler scheduler;
  late final DeviceController controller;
}

class _FakeDeviceBlePort implements DeviceBlePort {
  DeviceAdapterState _adapterState = DeviceAdapterState.on;
  DeviceBlePhase _phase = DeviceBlePhase.disconnected;
  final _adapterController =
      StreamController<DeviceAdapterState>.broadcast(sync: true);
  final _phaseController =
      StreamController<DeviceBlePhase>.broadcast(sync: true);
  final _telemetryController =
      StreamController<DeviceTelemetry>.broadcast(sync: true);
  final _infoController = StreamController<DeviceInfo>.broadcast(sync: true);
  final _powerController = StreamController<DevicePowerState>.broadcast(sync: true);

  Completer<String>? pairing;
  Completer<void>? savedConnection;
  void Function()? onDisconnect;
  Object? connectError;
  Future<void> forgetResult = Future.value();
  final List<String> savedConnectIds = [];
  final List<bool> muteWrites = [];
  int pairCalls = 0;
  int disconnectCalls = 0;
  int disposeCalls = 0;
  int powerOffWrites = 0;
  int cancelPowerOffWrites = 0;

  @override
  DeviceAdapterState get adapterState => _adapterState;

  @override
  Stream<DeviceAdapterState> get adapterStateStream =>
      _adapterController.stream;

  @override
  DeviceBlePhase get phase => _phase;

  @override
  Stream<DeviceBlePhase> get phaseStream => _phaseController.stream;

  @override
  Stream<DeviceTelemetry> get telemetryStream => _telemetryController.stream;

  @override
  Stream<DeviceInfo> get deviceInfoStream => _infoController.stream;

  @override
  Future<String> pair() {
    pairCalls++;
    return pairing?.future ?? Future.value('echo-paired');
  }

  @override
  Future<void> connectSaved(String remoteId) async {
    savedConnectIds.add(remoteId);
    final error = connectError;
    if (error != null) throw error;
    await savedConnection?.future;
  }

  @override
  Future<void> setMuted(bool muted) async => muteWrites.add(muted);

  final micGains = <int>[];

  @override
  Future<void> setMicGain(int gain) async => micGains.add(gain);

  @override
  Stream<DevicePowerState> get powerStateStream => _powerController.stream;

  @override
  Future<void> powerOff() async => powerOffWrites++;

  @override
  Future<void> cancelPowerOff() async => cancelPowerOffWrites++;

  void emitPower(DevicePowerState state) => _powerController.add(state);

  @override
  Future<void> forgetBond() => forgetResult;

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    onDisconnect?.call();
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }

  void emitAdapter(DeviceAdapterState state) {
    _adapterState = state;
    _adapterController.add(state);
  }

  void setAdapter(DeviceAdapterState state) {
    _adapterState = state;
  }

  void emitPhase(DeviceBlePhase value) {
    _phase = value;
    _phaseController.add(value);
  }

  void emitTelemetry(DeviceTelemetry telemetry) {
    _telemetryController.add(telemetry);
  }

  void emitInfo(DeviceInfo info) {
    _infoController.add(info);
  }

  bool get infoHasListener => _infoController.hasListener;
}

class _FakeIdentityStore implements DeviceIdentityStorePort {
  _FakeIdentityStore(this.value);

  String? value;
  final List<String> savedIds = [];
  int clearCalls = 0;

  @override
  Future<String?> loadRemoteId() async => value;

  @override
  Future<void> saveRemoteId(String remoteId) async {
    value = remoteId;
    savedIds.add(remoteId);
  }

  @override
  Future<void> clear() async {
    value = null;
    clearCalls++;
  }
}

class _FakeScheduler {
  final List<Duration> delays = [];
  final List<_FakeRetryHandle> handles = [];

  DeviceRetryHandle schedule(Duration delay, void Function() callback) {
    final handle = _FakeRetryHandle(callback);
    delays.add(delay);
    handles.add(handle);
    return handle;
  }

  void fire(int index) => handles[index].fire();
}

class _FakeRetryHandle implements DeviceRetryHandle {
  _FakeRetryHandle(this._callback);

  final void Function() _callback;
  bool isCancelled = false;

  void fire() {
    if (!isCancelled) _callback();
  }

  @override
  void cancel() => isCancelled = true;
}