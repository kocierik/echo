import 'dart:async';
import 'dart:typed_data';

import 'ble_packet_assembler.dart';

typedef BleSegmentUpload = Future<bool> Function(BleCompletedSegment segment);
typedef BleControlWrite = Future<void> Function(List<int> value);
typedef BleRetrySchedule = BleRetryHandle Function(
  Duration delay,
  void Function() callback,
);

abstract interface class BleRetryHandle {
  void cancel();
}

class BleRelayController {
  BleRelayController({
    required BleSegmentUpload upload,
    required BleControlWrite writeControl,
    BleRetrySchedule? scheduleRetry,
    this.uploadTimeout = const Duration(seconds: 25),
    this.onStatus,
  })  : _upload = upload,
        _writeControl = writeControl,
        _scheduleRetry = scheduleRetry ?? _scheduleTimer;

  static const _retryDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];

  final BleSegmentUpload _upload;
  final BleControlWrite _writeControl;
  final BleRetrySchedule _scheduleRetry;
  final Duration uploadTimeout;
  final void Function(String message, {required bool isError})? onStatus;

  Future<void> _controlTail = Future.value();
  Future<void>? _attempt;
  BleRetryHandle? _retry;
  BleCompletedSegment? _pendingSegment;
  int _retryIndex = 0;
  int _generation = 0;
  bool _connected = false;
  bool _disposed = false;

  Future<void> get attemptComplete => _attempt ?? Future.value();

  Future<void> sendControl(List<int> value) async {
    final generation = _generation;
    if (!_isConnectionGeneration(generation)) return;
    await _enqueueControl(value, generation);
  }

  void setConnected(bool connected) {
    if (_disposed || connected == _connected) return;
    _connected = connected;
    _generation++;
    if (!connected) {
      _cancelRetainedWork();
    }
  }

  Future<void> handleEvents(Iterable<BleAssemblerEvent> events) async {
    final generation = _generation;
    if (!_isConnectionGeneration(generation)) return;

    for (final event in events) {
      if (!_isConnectionGeneration(generation)) return;
      switch (event) {
        case BleSegmentStarted():
        case BleTransferProgress():
          break;
        case BleAckRequired():
          await _enqueueControl(_buildAck(event), generation);
        case BleRestartRequired():
          final segmentId = event.segmentId;
          if (segmentId != null) {
            await _enqueueControl(
              _buildSegmentCommand(0x12, segmentId),
              generation,
            );
          }
          if (!_isConnectionGeneration(generation)) return;
          onStatus?.call(
            'Segment restart requested: ${event.reason}',
            isError: true,
          );
        case BleSegmentCompleted():
          _acceptCompleted(event.segment, generation);
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _connected = false;
    _generation++;
    _cancelRetainedWork();
  }

  Future<void> _enqueueControl(List<int> value, int generation) {
    final operation = _controlTail.then((_) async {
      if (!_isConnectionGeneration(generation)) return;
      await _writeControl(value);
    });
    _controlTail = operation.catchError((Object error, StackTrace stackTrace) {
      if (_isConnectionGeneration(generation)) {
        onStatus?.call('BLE control write failed: $error', isError: true);
      }
    });
    return operation;
  }

  void _acceptCompleted(BleCompletedSegment segment, int generation) {
    if (_pendingSegment != null || !_isConnectionGeneration(generation)) return;
    _pendingSegment = segment;
    _retryIndex = 0;
    _attempt = _attemptUpload(segment, generation);
  }

  Future<void> _attemptUpload(
    BleCompletedSegment segment,
    int generation,
  ) async {
    if (!_isCurrent(segment, generation)) return;
    onStatus?.call('Uploading segment ${segment.id}', isError: false);

    var uploaded = false;
    try {
      uploaded = await _upload(segment).timeout(uploadTimeout);
    } catch (error) {
      if (_isCurrent(segment, generation)) {
        onStatus?.call('Segment ${segment.id} upload failed: $error', isError: true);
      }
    }

    if (!_isCurrent(segment, generation)) return;
    if (!uploaded) {
      _scheduleUploadRetry(segment, generation);
      return;
    }

    _retryIndex = 0;
    await _attemptUploadOk(segment, generation);
  }

  Future<void> _attemptUploadOk(
    BleCompletedSegment segment,
    int generation,
  ) async {
    if (!_isCurrent(segment, generation)) return;
    try {
      await _enqueueControl(
        _buildSegmentCommand(0x13, segment.id),
        generation,
      );
    } catch (_) {
      if (_isCurrent(segment, generation)) {
        _scheduleUploadOkRetry(segment, generation);
      }
      return;
    }
    if (!_isCurrent(segment, generation)) return;

    _pendingSegment = null;
    _retryIndex = 0;
    onStatus?.call('Segment ${segment.id} uploaded', isError: false);
  }

  void _scheduleUploadRetry(BleCompletedSegment segment, int generation) {
    _schedulePendingRetry(
      segment,
      generation,
      () => _attemptUpload(segment, generation),
    );
  }

  void _scheduleUploadOkRetry(BleCompletedSegment segment, int generation) {
    _schedulePendingRetry(
      segment,
      generation,
      () => _attemptUploadOk(segment, generation),
    );
  }

  void _schedulePendingRetry(
    BleCompletedSegment segment,
    int generation,
    Future<void> Function() retryAttempt,
  ) {
    final delayIndex = _retryIndex.clamp(0, _retryDelays.length - 1).toInt();
    final delay = _retryDelays[delayIndex];
    if (_retryIndex < _retryDelays.length - 1) _retryIndex++;
    _retry?.cancel();
    _retry = _scheduleRetry(delay, () {
      _retry = null;
      if (!_isCurrent(segment, generation)) return;
      _attempt = retryAttempt();
    });
  }

  bool _isConnectionGeneration(int generation) {
    return !_disposed && _connected && generation == _generation;
  }

  bool _isCurrent(BleCompletedSegment segment, int generation) {
    return _isConnectionGeneration(generation) &&
        identical(segment, _pendingSegment);
  }

  void _cancelRetainedWork() {
    _retry?.cancel();
    _retry = null;
    _pendingSegment = null;
    _retryIndex = 0;
    _attempt = null;
    _controlTail = Future.value();
  }

  static BleRetryHandle _scheduleTimer(
    Duration delay,
    void Function() callback,
  ) {
    return _TimerRetryHandle(Timer(delay, callback));
  }

  static Uint8List _buildAck(BleAckRequired event) {
    final bytes = Uint8List(7);
    final data = ByteData.sublistView(bytes);
    data.setUint8(0, 0x11);
    data.setUint32(1, event.segmentId, Endian.little);
    data.setUint16(5, event.highestSequence, Endian.little);
    return bytes;
  }

  static Uint8List _buildSegmentCommand(int type, int segmentId) {
    final bytes = Uint8List(5);
    final data = ByteData.sublistView(bytes);
    data.setUint8(0, type);
    data.setUint32(1, segmentId, Endian.little);
    return bytes;
  }
}

class _TimerRetryHandle implements BleRetryHandle {
  _TimerRetryHandle(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}