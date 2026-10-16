import 'dart:io';

import 'package:flutter/services.dart';

/// This phone's model, to tell it apart in Settings → Devices ("iPhone 15 Pro",
/// "Google Pixel 8"), from the "echo/device" channel (AppDelegate.swift,
/// MainActivity.kt); a plain "iPhone" / "Android phone" when it cannot be read.
Future<String> phoneName(
    {MethodChannel channel = const MethodChannel('echo/device')}) async {
  try {
    final raw = await channel.invokeMethod<String>('model') ?? '';
    if (Platform.isIOS) return iosModelName(raw);
    if (Platform.isAndroid) {
      final (maker, model) = switch (raw.split('|')) {
        [final maker, final model] => (maker, model),
        _ => ('', raw),
      };
      return androidModelName(maker, model);
    }
  } catch (_) {}
  return Platform.isIOS ? 'iPhone' : 'Android phone';
}

/// "iPhone16,1" → "iPhone 15 Pro"; an identifier not listed (or the simulator's)
/// is just "iPhone".
String iosModelName(String identifier) =>
    _iPhones[identifier.trim()] ?? 'iPhone';

/// "Google" + "Pixel 8" → "Google Pixel 8"; the maker is not repeated when the
/// model already starts with it.
String androidModelName(String maker, String model) {
  maker = maker.trim();
  model = model.trim();
  if (model.isEmpty) return 'Android phone';
  if (maker.isEmpty || model.toLowerCase().startsWith(maker.toLowerCase())) {
    return model;
  }
  return '${maker[0].toUpperCase()}${maker.substring(1)} $model';
}

const _iPhones = {
  'iPhone13,1': 'iPhone 12 mini',
  'iPhone13,2': 'iPhone 12',
  'iPhone13,3': 'iPhone 12 Pro',
  'iPhone13,4': 'iPhone 12 Pro Max',
  'iPhone14,4': 'iPhone 13 mini',
  'iPhone14,5': 'iPhone 13',
  'iPhone14,2': 'iPhone 13 Pro',
  'iPhone14,3': 'iPhone 13 Pro Max',
  'iPhone14,6': 'iPhone SE (3rd generation)',
  'iPhone14,7': 'iPhone 14',
  'iPhone14,8': 'iPhone 14 Plus',
  'iPhone15,2': 'iPhone 14 Pro',
  'iPhone15,3': 'iPhone 14 Pro Max',
  'iPhone15,4': 'iPhone 15',
  'iPhone15,5': 'iPhone 15 Plus',
  'iPhone16,1': 'iPhone 15 Pro',
  'iPhone16,2': 'iPhone 15 Pro Max',
  'iPhone17,1': 'iPhone 16 Pro',
  'iPhone17,2': 'iPhone 16 Pro Max',
  'iPhone17,3': 'iPhone 16',
  'iPhone17,4': 'iPhone 16 Plus',
  'iPhone17,5': 'iPhone 16e',
};
