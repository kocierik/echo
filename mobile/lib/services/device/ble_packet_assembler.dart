import 'dart:typed_data';

import 'device_protocol.dart';

const int _frameSegmentStart = 0x01;
const int _frameSegmentMetadata = 0x02;
const int _frameSegmentData = 0x03;
// Protocol 3: a photo transfer, otherwise like an audio segment
const int _framePhotoStart = 0x04;
// The versions the app speaks, one list for every frame
const Set<int> _protocolVersions = DeviceProtocol.supportedVersions;
const int _segmentStartSize = 20;
const int _segmentMetadataSize = 19;
const int _segmentDataHeaderSize = 7;
const int _maxSegmentDataSize = 244;
const int _ackWindowChunks = 32;

sealed class BleAssemblerEvent {
  const BleAssemblerEvent();
}

final class BleSegmentStarted extends BleAssemblerEvent {
  const BleSegmentStarted({
    required this.segmentId,
    required this.totalBytes,
    required this.totalChunks,
    required this.durationMs,
    this.isPhoto = false,
  });

  final int segmentId;
  final int totalBytes;
  final int totalChunks;
  final int durationMs;
  final bool isPhoto;
}

final class BleTransferProgress extends BleAssemblerEvent {
  const BleTransferProgress({
    required this.segmentId,
    required this.receivedBytes,
    required this.totalBytes,
    required this.receivedChunks,
    required this.totalChunks,
  });

  final int segmentId;
  final int receivedBytes;
  final int totalBytes;
  final int receivedChunks;
  final int totalChunks;
}

final class BleAckRequired extends BleAssemblerEvent {
  const BleAckRequired({
    required this.segmentId,
    required this.highestSequence,
  });

  final int segmentId;
  final int highestSequence;
}

final class BleSegmentCompleted extends BleAssemblerEvent {
  const BleSegmentCompleted(this.segment);

  final BleCompletedSegment segment;
}

final class BleRestartRequired extends BleAssemblerEvent {
  const BleRestartRequired({this.segmentId, required this.reason});

  final int? segmentId;
  final String reason;
}

final class BleCompletedSegment {
  BleCompletedSegment({
    required this.id,
    required List<int> adpcmBytes,
    required this.recordedAt,
    required this.durationMs,
    required this.silenceBeforeMs,
    required this.averageEnergy,
    this.isPhoto = false,
  }) : _adpcmBytes = Uint8List.fromList(adpcmBytes);

  final int id;
  final Uint8List _adpcmBytes;

  /// The payload: ADPCM audio, or a JPEG when [isPhoto].
  Uint8List get adpcmBytes => Uint8List.fromList(_adpcmBytes);
  Uint8List get jpegBytes => adpcmBytes;

  /// A photo from the wearable camera (recordedAt is when it was taken).
  final bool isPhoto;

  /// Firmware 0.11.0 on: id bit 30 marks audio whose opening held the wake phrase.
  static const wakeFlag = 0x40000000;

  /// The pendant heard its wake phrase in this segment's opening.
  bool get wakeHeard => !isPhoto && (id & wakeFlag) != 0;
  final DateTime recordedAt;
  final int durationMs;
  final int silenceBeforeMs;
  final int averageEnergy;
}

class BlePacketAssembler {
  int? _segmentId;
  bool _isPhoto = false;
  int _expectedLength = 0;
  int _durationMs = 0;
  int _totalChunks = 0;
  int _expectedCrc = 0;
  int _nextSequence = 0;
  DateTime? _recordedAt;
  int _silenceBeforeMs = 0;
  int _averageEnergy = 0;
  final List<int> _bytes = [];

  List<BleAssemblerEvent> add(List<int> value) {
    if (value.isEmpty) {
      return _restart('empty frame');
    }

    final packet = Uint8List.fromList(value);
    switch (packet[0]) {
      case _frameSegmentStart:
        return _addStart(packet, isPhoto: false);
      case _framePhotoStart:
        return _addStart(packet, isPhoto: true);
      case _frameSegmentMetadata:
        return _addMetadata(packet);
      case _frameSegmentData:
        return _addData(packet);
      default:
        return _restart('unknown frame type');
    }
  }

  void reset() {
    _segmentId = null;
    _isPhoto = false;
    _expectedLength = 0;
    _durationMs = 0;
    _totalChunks = 0;
    _expectedCrc = 0;
    _nextSequence = 0;
    _recordedAt = null;
    _silenceBeforeMs = 0;
    _averageEnergy = 0;
    _bytes.clear();
  }

  List<BleAssemblerEvent> _addStart(Uint8List packet, {required bool isPhoto}) {
    if (packet.length != _segmentStartSize) {
      return _restart('invalid segment-start length', packet: packet);
    }

    final data = ByteData.sublistView(packet);
    final segmentId = data.getUint32(1, Endian.little);
    if (_segmentId != null) {
      return _restart('unexpected segment start', segmentId: segmentId);
    }
    final version = data.getUint8(5);
    if (!_protocolVersions.contains(version) || (isPhoto && version < 3)) {
      return _restart('unsupported protocol version', segmentId: segmentId);
    }

    final totalLength = data.getUint32(6, Endian.little);
    final totalChunks = data.getUint16(14, Endian.little);
    if (totalLength == 0 || totalChunks == 0) {
      return _restart('invalid segment dimensions', segmentId: segmentId);
    }

    _segmentId = segmentId;
    _isPhoto = isPhoto;
    _expectedLength = totalLength;
    _durationMs = data.getUint32(10, Endian.little);
    _totalChunks = totalChunks;
    _expectedCrc = data.getUint32(16, Endian.little);
    return [
      BleSegmentStarted(
        segmentId: segmentId,
        totalBytes: totalLength,
        totalChunks: totalChunks,
        durationMs: _durationMs,
        isPhoto: isPhoto,
      ),
    ];
  }

  List<BleAssemblerEvent> _addMetadata(Uint8List packet) {
    if (packet.length != _segmentMetadataSize) {
      return _restart('invalid metadata length', packet: packet);
    }

    final data = ByteData.sublistView(packet);
    final segmentId = data.getUint32(1, Endian.little);
    if (_segmentId == null || segmentId != _segmentId) {
      return _restart('metadata segment ID mismatch', segmentId: segmentId);
    }
    if (_recordedAt != null || _nextSequence != 0) {
      return _restart('unexpected metadata', segmentId: segmentId);
    }

    final unixSeconds = data.getUint64(5, Endian.little);
    _recordedAt = DateTime.fromMillisecondsSinceEpoch(
      unixSeconds * Duration.millisecondsPerSecond,
      isUtc: true,
    );
    _silenceBeforeMs = data.getUint32(13, Endian.little);
    _averageEnergy = data.getUint16(17, Endian.little);
    return const [];
  }

  List<BleAssemblerEvent> _addData(Uint8List packet) {
    if (packet.length <= _segmentDataHeaderSize ||
      packet.length > _maxSegmentDataSize) {
      return _restart('invalid data-frame length', packet: packet);
    }

    final data = ByteData.sublistView(packet);
    final segmentId = data.getUint32(1, Endian.little);
    final sequence = data.getUint16(5, Endian.little);
    if (_segmentId == null || segmentId != _segmentId) {
      return _restart('data segment ID mismatch', segmentId: segmentId);
    }
    if (_recordedAt == null) {
      return _restart('segment metadata missing', segmentId: segmentId);
    }
    if (sequence != _nextSequence) {
      return _restart('non-contiguous data sequence', segmentId: segmentId);
    }
    if (sequence >= _totalChunks) {
      return _restart('too many data chunks', segmentId: segmentId);
    }

    _bytes.addAll(packet.sublist(_segmentDataHeaderSize));
    _nextSequence++;
    if (_bytes.length > _expectedLength) {
      return _restart('segment exceeds expected length', segmentId: segmentId);
    }

    final isLastChunk = _nextSequence == _totalChunks;
    if (!isLastChunk && _bytes.length == _expectedLength) {
      return _restart('segment completed before final chunk', segmentId: segmentId);
    }
    final progress = BleTransferProgress(
      segmentId: segmentId,
      receivedBytes: _bytes.length,
      totalBytes: _expectedLength,
      receivedChunks: _nextSequence,
      totalChunks: _totalChunks,
    );
    if (!isLastChunk) {
      if (_nextSequence % _ackWindowChunks == 0) {
        return [
          progress,
          BleAckRequired(
            segmentId: segmentId,
            highestSequence: sequence,
          ),
        ];
      }
      return [progress];
    }

    if (_bytes.length != _expectedLength) {
      return _restart('segment length mismatch', segmentId: segmentId);
    }
    if (bleCrc32(_bytes) != _expectedCrc) {
      return _restart('segment CRC mismatch', segmentId: segmentId);
    }

    final completed = BleCompletedSegment(
      id: segmentId,
      adpcmBytes: _bytes,
      recordedAt: _recordedAt!,
      durationMs: _durationMs,
      silenceBeforeMs: _silenceBeforeMs,
      averageEnergy: _averageEnergy,
      isPhoto: _isPhoto,
    );
    final events = <BleAssemblerEvent>[
      progress,
      BleAckRequired(
        segmentId: segmentId,
        highestSequence: sequence,
      ),
      BleSegmentCompleted(completed),
    ];
    reset();
    return events;
  }

  List<BleAssemblerEvent> _restart(
    String reason, {
    int? segmentId,
    Uint8List? packet,
  }) {
    final restartSegmentId = segmentId ?? _segmentId ?? _readSegmentId(packet);
    reset();
    return [BleRestartRequired(segmentId: restartSegmentId, reason: reason)];
  }

  int? _readSegmentId(Uint8List? packet) {
    if (packet == null || packet.length < 5) return null;
    return ByteData.sublistView(packet).getUint32(1, Endian.little);
  }
}

int bleCrc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      final mask = -(crc & 1);
      crc = ((crc >> 1) ^ (0xedb88320 & mask)) & 0xffffffff;
    }
  }
  return (~crc) & 0xffffffff;
}