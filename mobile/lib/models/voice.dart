import 'package:flutter/foundation.dart';

/// A known voice: the user's own or a person named in a transcript.
@immutable
final class VoiceProfile {
  const VoiceProfile({
    required this.id,
    required this.name,
    required this.isSelf,
    this.personId,
    this.sampleCount = 0,
  });

  factory VoiceProfile.fromJson(Map<String, dynamic> json) => VoiceProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        isSelf: json['is_self'] as bool? ?? false,
        personId: json['person_id'] as String?,
        sampleCount: json['sample_count'] as int? ?? 0,
      );

  final String id;
  final String name;
  final bool isSelf;
  final String? personId;

  /// How many segments the voice was learned from.
  final int sampleCount;
}

@immutable
final class VoiceProfiles {
  const VoiceProfiles({required this.fingerprintsEnabled, required this.items});

  factory VoiceProfiles.fromJson(Map<String, dynamic> json) => VoiceProfiles(
        fingerprintsEnabled: json['fingerprints_enabled'] as bool? ?? false,
        items: [
          for (final item in json['items'] as List<dynamic>? ?? const [])
            VoiceProfile.fromJson(item as Map<String, dynamic>),
        ],
      );

  /// False when the server has no voice model: voices cannot be recognised.
  final bool fingerprintsEnabled;
  final List<VoiceProfile> items;

  VoiceProfile? get own => items.where((v) => v.isSelf).firstOrNull;
  List<VoiceProfile> get others => items.where((v) => !v.isSelf).toList();
}

/// "done", "waiting" (still being transcribed: ask again) or "no_speech".
@immutable
final class VoiceEnrollment {
  const VoiceEnrollment({required this.status, this.segments = 0});

  factory VoiceEnrollment.fromJson(Map<String, dynamic> json) => VoiceEnrollment(
        status: json['status'] as String,
        segments: json['segments'] as int? ?? 0,
      );

  final String status;
  final int segments;
}
