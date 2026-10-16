/// A phone signed in to the account (one API key each).
final class SignedInDevice {
  const SignedInDevice({
    required this.id,
    required this.name,
    required this.current,
    this.platform,
    this.createdAt,
    this.lastUsedAt,
  });

  factory SignedInDevice.fromJson(Map<String, dynamic> json) => SignedInDevice(
        id: json['id'] as String,
        name: json['name'] as String,
        platform: json['platform'] as String?,
        createdAt: _date(json['created_at']),
        lastUsedAt: _date(json['last_used_at']),
        current: json['current'] as bool? ?? false,
      );

  final String id;
  final String name;

  /// "ios" or "android"; null for a key made on the server.
  final String? platform;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;

  /// This phone.
  final bool current;
}

DateTime? _date(Object? value) => value is String ? DateTime.tryParse(value) : null;
