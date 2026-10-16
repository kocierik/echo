import 'package:flutter/foundation.dart';

/// The words that differ between an iPhone and an Android phone, by the platform Flutter
/// reports (tests pick one with TargetPlatformVariant).
abstract final class PhoneWords {
  static bool get isIPhone => defaultTargetPlatform == TargetPlatform.iOS;

  /// "iPhone" or "phone": "the calendar on this phone".
  static String get phone => isIPhone ? 'iPhone' : 'phone';

  /// The Settings page with Reminders and Calendar.
  static String get onThisPhone => 'On this $phone';

  /// Where a permission refused once is given back.
  static String get systemSettings => isIPhone ? 'iOS Settings' : 'Android settings';
}
