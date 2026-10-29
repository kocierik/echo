import 'dart:async';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../models/device_status.dart';
import 'device_protocol.dart';

/// A firmware the server offers (`GET /firmware/latest`).
final class FirmwareRelease {
  const FirmwareRelease({
    required this.version,
    required this.sizeBytes,
    required this.sha256,
    this.signature,
    this.notes,
  });

  factory FirmwareRelease.fromJson(Map<String, dynamic> json) =>
      FirmwareRelease(
        version: json['version'] as String,
        sizeBytes: json['size_bytes'] as int,
        sha256: json['sha256'] as String,
        signature: json['signature'] as String?,
        notes: json['notes'] as String?,
      );

  final String version;
  final int sizeBytes;

  /// Hex, as the server computed it.
  final String sha256;

  /// The release key's signature of [sha256] (hex r||s): a wearable on protocol 6 installs
  /// nothing else. Null for releases published before.
  final String? signature;
  final String? notes;
}

abstract interface class FirmwareApi {
  Future<FirmwareRelease?> latestFirmware();
  Future<Uint8List> downloadFirmware(String version);
}

/// The wearable as a firmware update sees it (BleService).
abstract interface class FirmwareLink {
  /// Connected, with the OTA characteristic (protocol 4).
  bool get canUpdateFirmware;

  /// Image bytes per OTA write, from the negotiated MTU.
  int get firmwareChunkSize;
  Stream<OtaStatus> get otaStatusStream;

  /// DEVICE_INFO, sent by the wearable each time the app connects.
  Stream<DeviceInfo> get deviceInfoStream;
  /// [signature]: the release key's, for a wearable on protocol 6; null before.
  Future<void> beginFirmwareUpdate(int size, List<int> sha256, List<int>? signature);
  Future<void> writeFirmwareChunk(int offset, List<int> bytes);
  Future<void> abortFirmwareUpdate();
}

/// (major, minor, patch) of "0.5.0"; null for anything else.
List<int>? parseFirmwareVersion(String? version) {
  if (version == null) return null;
  final parts = version.split('.');
  if (parts.length != 3) return null;
  final numbers = parts.map(int.tryParse).toList();
  if (numbers.any((n) => n == null || n < 0)) return null;
  return numbers.cast<int>();
}

bool isNewerFirmware(String candidate, String? installed) {
  final a = parseFirmwareVersion(candidate);
  final b = parseFirmwareVersion(installed);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

enum FirmwareUpdatePhase {
  /// Nothing known yet, or no newer firmware.
  idle,

  /// A newer firmware, and the wearable can take it over Bluetooth.
  available,

  /// A firmware is published, but the wearable's predates updates over Bluetooth:
  /// the first one with them goes over the cable.
  needsCable,

  /// Waiting for the wearable to send what it still holds.
  syncing,
  downloading,
  sending,

  /// Sent and checked: the wearable restarts into it.
  restarting,
  done,
  failed,
}

@immutable
final class FirmwareUpdateState {
  const FirmwareUpdateState({
    this.phase = FirmwareUpdatePhase.idle,
    this.release,
    this.progress = 0,
    this.message,
  });

  final FirmwareUpdatePhase phase;
  final FirmwareRelease? release;

  /// 0-1 while sending.
  final double progress;

  /// What went wrong (failed) or what happened (done).
  final String? message;

  bool get busy => const {
        FirmwareUpdatePhase.syncing,
        FirmwareUpdatePhase.downloading,
        FirmwareUpdatePhase.sending,
        FirmwareUpdatePhase.restarting,
      }.contains(phase);
}

/// Firmware updates, started by the user (Settings → Device):
///
/// 1. the wearable sends the audio and photos it still holds (a restart loses RAM);
/// 2. the image is downloaded and checked against the server's SHA-256;
/// 3. it goes to the wearable in order, one acknowledged write at a time; the wearable
///    pauses its microphone, checks the SHA-256 again, and restarts into it;
/// 4. the update is done when the wearable comes back reporting the new version. If the
///    new firmware cannot reach the app, the wearable goes back to the previous one.
final class FirmwareUpdateController
    extends ValueNotifier<FirmwareUpdateState> {
  FirmwareUpdateController({
    required FirmwareApi api,
    required FirmwareLink link,
    required DeviceStatus Function() device,
    this.syncTimeout = const Duration(minutes: 2),
    this.statusTimeout = const Duration(seconds: 20),
    this.restartTimeout = const Duration(minutes: 7),
    this.pollInterval = const Duration(seconds: 1),
    this.checkInterval = const Duration(hours: 1),
  })  : _api = api,
        _link = link,
        _device = device,
        super(const FirmwareUpdateState());

  final FirmwareApi _api;
  final FirmwareLink _link;
  final DeviceStatus Function() _device;
  final Duration syncTimeout;
  final Duration statusTimeout;
  final Duration restartTimeout;
  final Duration pollInterval;
  final Duration checkInterval;
  bool _cancelled = false;
  bool _disposed = false;

  FirmwareRelease? _latest;
  DateTime? _fetchedAt;

  /// Asks the server for the latest firmware (at most every [checkInterval] unless
  /// `force`d) and compares it with the wearable's.
  Future<void> check({bool force = false}) async {
    if (value.busy || _disposed) return;
    final fetchedAt = _fetchedAt;
    if (force ||
        fetchedAt == null ||
        clock.now().difference(fetchedAt) >= checkInterval) {
      try {
        _latest = await _api.latestFirmware();
        _fetchedAt = clock.now();
      } catch (_) {
        return; // offline: try again on the next check
      }
      if (_disposed || value.busy) return;
      if (value.phase == FirmwareUpdatePhase.done) {
        value = const FirmwareUpdateState();
      }
    }
    deviceChanged();
  }

  /// The wearable connected or reported another version: compare again, without asking
  /// the server. A failure or a finished update stays on screen until the next check.
  void deviceChanged() {
    if (_disposed || value.busy) return;
    if (value.phase == FirmwareUpdatePhase.failed ||
        value.phase == FirmwareUpdatePhase.done) {
      return;
    }
    final release = _latest;
    final device = _device();
    final connected =
        device.connectionState == DeviceConnectionState.listening ||
            device.connectionState == DeviceConnectionState.muted;
    final FirmwareUpdatePhase phase;
    if (release == null || !connected) {
      phase = FirmwareUpdatePhase.idle;
    } else if (device.firmwareVersion == null ||
        (device.protocolVersion ?? 0) < DeviceProtocol.otaVersion) {
      // A firmware from before updates over Bluetooth does not even say its version
      phase = FirmwareUpdatePhase.needsCable;
    } else if (isNewerFirmware(release.version, device.firmwareVersion)) {
      phase = FirmwareUpdatePhase.available;
    } else {
      phase = FirmwareUpdatePhase.idle;
    }
    final next = phase == FirmwareUpdatePhase.idle
        ? const FirmwareUpdateState()
        : FirmwareUpdateState(phase: phase, release: release);
    if (next.phase != value.phase ||
        next.release?.version != value.release?.version) {
      value = next;
    }
  }

  /// Stops a transfer in progress; the wearable keeps its current firmware.
  Future<void> cancel() async {
    if (!value.busy || value.phase == FirmwareUpdatePhase.restarting) return;
    _cancelled = true;
    try {
      await _link.abortFirmwareUpdate();
    } catch (_) {}
  }

  Future<void> install() async {
    final release = value.release;
    if (release == null || value.phase != FirmwareUpdatePhase.available) return;
    _cancelled = false;
    // The wearable's latest OTA_STATUS: READY to receive, then DONE, or FAILED at any point
    OtaStatus? latest;
    final statusSubscription =
        _link.otaStatusStream.listen((status) => latest = status);
    try {
      if (!_link.canUpdateFirmware) {
        throw const _UpdateFailure('Connect Echo to update it.');
      }
      _set(FirmwareUpdatePhase.syncing, release);
      await _waitUntilSynced();

      _set(FirmwareUpdatePhase.downloading, release);
      final image = await _download(release);

      _set(FirmwareUpdatePhase.sending, release);
      await _link.beginFirmwareUpdate(
          image.length, sha256.convert(image).bytes, _signatureFor(release));
      final ready = await _waitForStatus(() => latest, (_) => true);
      if (ready.state != OtaState.receiving) _throwStatus(ready);

      final chunkSize = _link.firmwareChunkSize;
      for (var offset = 0; offset < image.length; offset += chunkSize) {
        if (_cancelled) throw const _UpdateFailure('Update cancelled.');
        final status = latest;
        if (status != null && status.state == OtaState.failed) {
          _throwStatus(status);
        }
        if (!_link.canUpdateFirmware) {
          throw const _UpdateFailure(
            'Echo disconnected during the update. It still has its previous firmware.',
          );
        }
        final end = offset + chunkSize < image.length
            ? offset + chunkSize
            : image.length;
        await _link.writeFirmwareChunk(
            offset, Uint8List.sublistView(image, offset, end));
        _set(FirmwareUpdatePhase.sending, release,
            progress: end / image.length);
      }
      final done = await _waitForStatus(
          () => latest, (s) => s.state != OtaState.receiving);
      if (done.state != OtaState.done) _throwStatus(done);

      _set(FirmwareUpdatePhase.restarting, release, progress: 1);
      final info = await _link.deviceInfoStream.first.timeout(restartTimeout);
      final version =
          '${info.firmwareMajor}.${info.firmwareMinor}.${info.firmwarePatch}';
      if (version != release.version) {
        throw _UpdateFailure(
          'Echo could not start ${release.version} and went back to $version.',
        );
      }
      _set(FirmwareUpdatePhase.done, release,
          progress: 1, message: 'Echo is up to date (${release.version}).');
    } on _UpdateFailure catch (failure) {
      await _abortIfSending();
      _fail(release, failure.message);
    } on TimeoutException {
      final restarting = value.phase == FirmwareUpdatePhase.restarting;
      if (!restarting) await _abortIfSending();
      _fail(
        release,
        restarting
            ? 'Echo did not come back. If it does not reconnect in a few minutes, it '
                'returns to its previous firmware by itself.'
            : 'Echo stopped answering. It still has its previous firmware.',
      );
    } catch (_) {
      final downloading = value.phase == FirmwareUpdatePhase.downloading;
      await _abortIfSending();
      _fail(
        release,
        downloading
            ? 'Could not download the update. Check the connection to your server.'
            : 'The update was interrupted. Echo still has its previous firmware.',
      );
    } finally {
      await statusSubscription.cancel();
    }
  }

  Future<void> _abortIfSending() async {
    if (value.phase != FirmwareUpdatePhase.sending ||
        !_link.canUpdateFirmware) {
      return;
    }
    try {
      await _link.abortFirmwareUpdate();
    } catch (_) {}
  }

  Future<void> _waitUntilSynced() async {
    final deadline = clock.now().add(syncTimeout);
    while (true) {
      final device = _device();
      if (device.bufferCount == 0 && device.bufferBytes == 0) return;
      if (_cancelled) throw const _UpdateFailure('Update cancelled.');
      if (clock.now().isAfter(deadline)) {
        throw const _UpdateFailure(
          'Echo still has audio to send. Try again once it has synced '
          '(on Wi-Fi, if uploads wait for it).',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  /// What OTA_BEGIN carries: nothing for a wearable from before signed updates, which
  /// would not understand it; the signature for one that checks it.
  List<int>? _signatureFor(FirmwareRelease release) {
    if ((_device().protocolVersion ?? 0) < DeviceProtocol.signedOtaVersion) return null;
    final hex = release.signature;
    if (hex == null || hex.length != 128) {
      throw const _UpdateFailure(
          'This firmware is not signed by Echo, so Echo would refuse it.');
    }
    return [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
  }

  Future<Uint8List> _download(FirmwareRelease release) async {
    final image = await _api.downloadFirmware(release.version);
    if (image.length != release.sizeBytes ||
        sha256.convert(image).toString() != release.sha256.toLowerCase()) {
      throw const _UpdateFailure('The download arrived damaged. Try again.');
    }
    return image;
  }

  /// The latest status once it is one `accept`s; TimeoutException after [statusTimeout].
  Future<OtaStatus> _waitForStatus(
    OtaStatus? Function() latest,
    bool Function(OtaStatus) accept,
  ) async {
    final deadline = clock.now().add(statusTimeout);
    while (true) {
      final status = latest();
      if (status != null &&
          (accept(status) || status.state == OtaState.failed)) {
        return status;
      }
      if (clock.now().isAfter(deadline)) {
        throw TimeoutException('No OTA status');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Never _throwStatus(OtaStatus status) =>
      throw _UpdateFailure(DeviceProtocol.otaErrorMessage(status.error));

  void _set(
    FirmwareUpdatePhase phase,
    FirmwareRelease release, {
    double progress = 0,
    String? message,
  }) {
    if (_disposed) return;
    value = FirmwareUpdateState(
      phase: phase,
      release: release,
      progress: progress,
      message: message,
    );
  }

  void _fail(FirmwareRelease release, String message) =>
      _set(FirmwareUpdatePhase.failed, release, message: message);

  /// After a failure, offer the update again.
  void reset() {
    if (value.phase != FirmwareUpdatePhase.failed) return;
    value = FirmwareUpdateState(
        phase: FirmwareUpdatePhase.available, release: value.release);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final class _UpdateFailure implements Exception {
  const _UpdateFailure(this.message);
  final String message;
}
