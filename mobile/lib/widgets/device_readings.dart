import 'package:flutter/material.dart';

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

/// "2 min of speech to sync" (null under 10 s: it is about to arrive anyway).
String? pendingSpeechLabel(int bytes) {
  final seconds = bytes ~/ _adpcmBytesPerSecond;
  if (seconds < 10) return null;
  if (seconds < 60) return '$seconds s of speech to sync';
  return '${(seconds / 60).round()} min of speech to sync';
}
