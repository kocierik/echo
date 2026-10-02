import 'dart:typed_data';

import 'package:echo_app/services/ble_packet_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const segmentId = 0x12345678;
  final recordedAt = DateTime.utc(2026, 8, 2, 12, 30, 45);

  group('BlePacketAssembler', () {
    test('uses the firmware CRC32 polynomial and final XOR', () {
      expect(bleCrc32('123456789'.codeUnits), 0xcbf43926);
    });

    test('assembles a valid segment and preserves firmware metadata', () {
      final audio = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
      final assembler = BlePacketAssembler();

      expect(
        assembler.add(_start(
          segmentId: segmentId,
          totalLength: audio.length,
          durationMs: 6000,
          totalChunks: 2,
          crc: bleCrc32(audio),
        )),
        [isA<BleSegmentStarted>()],
      );
      expect(
        assembler.add(_metadata(
          segmentId: segmentId,
          recordedAt: recordedAt,
          silenceBeforeMs: 640,
          averageEnergy: 321,
        )),
        isEmpty,
      );
      expect(
        assembler.add(_data(segmentId, 0, audio.sublist(0, 3))),
        [isA<BleTransferProgress>()],
      );

      final events = assembler.add(_data(segmentId, 1, audio.sublist(3)));

      expect(events, hasLength(3));
      expect(
        events[1],
        isA<BleAckRequired>()
            .having((event) => event.segmentId, 'segmentId', segmentId)
            .having((event) => event.highestSequence, 'highestSequence', 1),
      );
      expect(
        events.last,
        isA<BleSegmentCompleted>()
            .having((event) => event.segment.id, 'id', segmentId)
            .having((event) => event.segment.adpcmBytes, 'audio', orderedEquals(audio))
            .having((event) => event.segment.recordedAt, 'recordedAt', recordedAt)
            .having((event) => event.segment.durationMs, 'durationMs', 6000)
            .having((event) => event.segment.silenceBeforeMs, 'silenceBeforeMs', 640)
            .having((event) => event.segment.averageEnergy, 'averageEnergy', 321),
      );
    });

    test('emits cumulative acknowledgements at 32 chunks and the final chunk', () {
      final audio = Uint8List.fromList(List<int>.generate(33, (index) => index));
      final assembler = BlePacketAssembler();
      assembler.add(_start(
        segmentId: segmentId,
        totalLength: audio.length,
        durationMs: 1000,
        totalChunks: 33,
        crc: bleCrc32(audio),
      ));
      assembler.add(_metadata(segmentId: segmentId, recordedAt: recordedAt));

      for (var sequence = 0; sequence < 31; sequence++) {
        expect(
          assembler.add(_data(segmentId, sequence, [audio[sequence]])),
          [isA<BleTransferProgress>()],
        );
      }
      final windowEvents = assembler.add(_data(segmentId, 31, [audio[31]]));
      expect(windowEvents.first, isA<BleTransferProgress>());
      expect(
        windowEvents.last,
        isA<BleAckRequired>().having((event) => event.highestSequence, 'highestSequence', 31),
      );
      final finalEvents = assembler.add(_data(segmentId, 32, [audio[32]]));
      expect(finalEvents.first, isA<BleTransferProgress>());
      expect(finalEvents[1], isA<BleAckRequired>().having((event) => event.highestSequence, 'highestSequence', 32));
      expect(finalEvents.last, isA<BleSegmentCompleted>());
    });

    test('rejects wrong fixed-frame lengths and protocol version', () {
      final validStart = _start(
        segmentId: segmentId,
        totalLength: 1,
        durationMs: 1,
        totalChunks: 1,
        crc: bleCrc32([1]),
      );
      final assembler = BlePacketAssembler();

      expect(assembler.add(validStart.sublist(0, validStart.length - 1)), _restart);
      expect(assembler.add([...validStart, 0]), _restart);
      final wrongVersion = Uint8List.fromList(validStart)..[5] = 1;
      expect(assembler.add(wrongVersion), _restart);

      expect(
        assembler.add(validStart),
        [
          isA<BleSegmentStarted>()
              .having((event) => event.segmentId, 'segmentId', segmentId)
              .having((event) => event.totalBytes, 'totalBytes', 1)
              .having((event) => event.totalChunks, 'totalChunks', 1)
              .having((event) => event.durationMs, 'durationMs', 1),
        ],
      );
      final metadata = _metadata(segmentId: segmentId, recordedAt: recordedAt);
      expect(assembler.add(metadata.sublist(0, metadata.length - 1)), _restart);
    });

    test('rejects empty and MTU-247 oversized data payloads', () {
      final emptyPayload = _startedAssembler(
        segmentId: segmentId,
        recordedAt: recordedAt,
        audio: [1],
        totalChunks: 1,
      );
      expect(emptyPayload.add(_data(segmentId, 0, const [])), _restart);

      final oversizedPayload = _startedAssembler(
        segmentId: segmentId,
        recordedAt: recordedAt,
        audio: List<int>.filled(238, 1),
        totalChunks: 1,
      );
      expect(
        oversizedPayload.add(_data(segmentId, 0, List<int>.filled(238, 1))),
        _restart,
      );
    });

    test('rejects missing, out-of-order, duplicate, and wrong-ID chunks', () {
      for (final invalidPacket in <List<int> Function()>[
        () => _data(segmentId, 1, [2]),
        () => _data(segmentId, 0, [1]),
        () => _data(segmentId + 1, 0, [1]),
      ]) {
        final assembler = _startedAssembler(
          segmentId: segmentId,
          recordedAt: recordedAt,
          audio: [1, 2],
          totalChunks: 2,
        );
        if (invalidPacket().elementAt(5) == 0 && invalidPacket().elementAt(1) == 0x78) {
          assembler.add(_data(segmentId, 0, [1]));
        }
        expect(assembler.add(invalidPacket()), _restart);
      }
    });

    test('rejects metadata and data with the wrong segment ID', () {
      final assembler = BlePacketAssembler();
      assembler.add(_start(
        segmentId: segmentId,
        totalLength: 1,
        durationMs: 1,
        totalChunks: 1,
        crc: bleCrc32([1]),
      ));
      expect(
        assembler.add(_metadata(segmentId: segmentId + 1, recordedAt: recordedAt)),
        _restart,
      );

      final restarted = _startedAssembler(
        segmentId: segmentId,
        recordedAt: recordedAt,
        audio: [1],
        totalChunks: 1,
      );
      expect(restarted.add(_data(segmentId + 1, 0, [1])), _restart);
    });

    test('rejects unexpected duplicate metadata', () {
      final assembler = _startedAssembler(
        segmentId: segmentId,
        recordedAt: recordedAt,
        audio: [1],
        totalChunks: 1,
      );
      expect(
        assembler.add(_metadata(segmentId: segmentId, recordedAt: recordedAt)),
        _restart,
      );
    });

    test('rejects total byte length and chunk count mismatches', () {
      final tooManyBytes = _startedAssembler(
        segmentId: segmentId,
        recordedAt: recordedAt,
        audio: [1],
        totalChunks: 1,
        declaredLength: 1,
      );
      expect(tooManyBytes.add(_data(segmentId, 0, [1, 2])), _restart);

      final tooFewBytes = _startedAssembler(
        segmentId: segmentId,
        recordedAt: recordedAt,
        audio: [1, 2],
        totalChunks: 1,
        declaredLength: 2,
      );
      expect(tooFewBytes.add(_data(segmentId, 0, [1])), _restart);

      final extraChunk = _startedAssembler(
        segmentId: segmentId,
        recordedAt: recordedAt,
        audio: [1, 2],
        totalChunks: 1,
      );
      expect(extraChunk.add(_data(segmentId, 0, [1])), _restart);
    });

    test('rejects CRC mismatch without acknowledging the final chunk', () {
      final assembler = BlePacketAssembler();
      assembler.add(_start(
        segmentId: segmentId,
        totalLength: 2,
        durationMs: 10,
        totalChunks: 1,
        crc: 0,
      ));
      assembler.add(_metadata(segmentId: segmentId, recordedAt: recordedAt));

      expect(assembler.add(_data(segmentId, 0, [1, 2])), _restart);
    });

    test('clears partial state after restart and on explicit reset', () {
      final assembler = _startedAssembler(
        segmentId: segmentId,
        recordedAt: recordedAt,
        audio: [1, 2],
        totalChunks: 2,
      );
      assembler.add(_data(segmentId, 0, [1]));
      expect(assembler.add(_data(segmentId, 0, [1])), _restart);
      expect(assembler.add(_data(segmentId, 1, [2])), _restart);

      assembler.add(_start(
        segmentId: segmentId,
        totalLength: 1,
        durationMs: 1,
        totalChunks: 1,
        crc: bleCrc32([9]),
      ));
      assembler.reset();
      expect(assembler.add(_metadata(segmentId: segmentId, recordedAt: recordedAt)), _restart);
    });
  });
}

final _restart = [isA<BleRestartRequired>()];

BlePacketAssembler _startedAssembler({
  required int segmentId,
  required DateTime recordedAt,
  required List<int> audio,
  required int totalChunks,
  int? declaredLength,
}) {
  final assembler = BlePacketAssembler();
  assembler.add(_start(
    segmentId: segmentId,
    totalLength: declaredLength ?? audio.length,
    durationMs: 100,
    totalChunks: totalChunks,
    crc: bleCrc32(audio),
  ));
  assembler.add(_metadata(segmentId: segmentId, recordedAt: recordedAt));
  return assembler;
}

Uint8List _start({
  required int segmentId,
  required int totalLength,
  required int durationMs,
  required int totalChunks,
  required int crc,
}) {
  final bytes = Uint8List(20);
  final data = ByteData.sublistView(bytes);
  data.setUint8(0, 0x01);
  data.setUint32(1, segmentId, Endian.little);
  data.setUint8(5, 2);
  data.setUint32(6, totalLength, Endian.little);
  data.setUint32(10, durationMs, Endian.little);
  data.setUint16(14, totalChunks, Endian.little);
  data.setUint32(16, crc, Endian.little);
  return bytes;
}

Uint8List _metadata({
  required int segmentId,
  required DateTime recordedAt,
  int silenceBeforeMs = 0,
  int averageEnergy = 0,
}) {
  final bytes = Uint8List(19);
  final data = ByteData.sublistView(bytes);
  data.setUint8(0, 0x02);
  data.setUint32(1, segmentId, Endian.little);
  data.setUint64(5, recordedAt.millisecondsSinceEpoch ~/ 1000, Endian.little);
  data.setUint32(13, silenceBeforeMs, Endian.little);
  data.setUint16(17, averageEnergy, Endian.little);
  return bytes;
}

Uint8List _data(int segmentId, int sequence, List<int> payload) {
  final bytes = Uint8List(7 + payload.length);
  final data = ByteData.sublistView(bytes);
  data.setUint8(0, 0x03);
  data.setUint32(1, segmentId, Endian.little);
  data.setUint16(5, sequence, Endian.little);
  bytes.setRange(7, bytes.length, payload);
  return bytes;
}