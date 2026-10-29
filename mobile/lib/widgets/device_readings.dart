import 'package:flutter/material.dart';

import '../models/device_status.dart';

/// Below this the battery shows in red.
const lowBatteryPercent = 15;

IconData batteryIcon(int percent) => switch (percent) {
      >= 90 => Icons.battery_full_rounded,
      >= 60 => Icons.battery_5_bar_rounded,
      >= 35 => Icons.battery_3_bar_rounded,
      >= lowBatteryPercent => Icons.battery_2_bar_rounded,
      _ => Icons.battery_alert_rounded,
    };

/// ADPCM at 16 kHz: 8 KB a second.
const _adpcmBytesPerSecond = 8 * 1024;

/// "29.1 GB free of 29.7 GB · 12 min of speech on it", or why there is no card in use.
String microSdLabel(MicroSd card) {
  if (!card.inUse) {
    return 'No card: speech that does not fit in Echo\'s memory (about 13 min) is lost';
  }
  final room = '${_size(card.freeMb)} free of ${_size(card.totalMb)}';
  final seconds = card.pendingKb * 1024 ~/ _adpcmBytesPerSecond;
  if (seconds < 60) return room;
  return '$room · ${(seconds / 60).round()} min of speech on it';
}

String _size(int mb) => mb < 1024 ? '$mb MB' : '${(mb / 1024).toStringAsFixed(1)} GB';

/// "2 min of speech to sync" (null under 10 s: it is about to arrive anyway).
String? pendingSpeechLabel(int bytes) {
  final seconds = bytes ~/ _adpcmBytesPerSecond;
  if (seconds < 10) return null;
  if (seconds < 60) return '$seconds s of speech to sync';
  return '${(seconds / 60).round()} min of speech to sync';
}
